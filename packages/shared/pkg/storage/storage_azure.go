package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/bloberror"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/container"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/sas"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/service"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
)

const (
	azureOperationTimeout = 5 * time.Second
	azureWriteTimeout     = 30 * time.Second
	azureReadTimeout      = 15 * time.Second

	// azureStorageAccountEnv names the storage account that owns the container
	// passed as "bucketName". The blob endpoint is derived as
	// https://<account>.blob.core.windows.net/.
	azureStorageAccountEnv = "AZURE_STORAGE_ACCOUNT"

	// azureStorageKeyEnv, when set, authenticates with the storage account's
	// shared key instead of the default credential chain (managed identity).
	// This avoids needing an RBAC role assignment (Storage Blob Data
	// Contributor), which requires Owner on the subscription to grant.
	azureStorageKeyEnv = "AZURE_STORAGE_KEY"
)

// azureStorage is the Azure Blob Storage backend. It mirrors awsStorage: a
// container maps to a "bucket", auth uses the default credential chain
// (managed identity on the VM, or env), and compression is unsupported
// (framed/compressed builds target GCP only), matching the AWS backend.
type azureStorage struct {
	client        *azblob.Client
	serviceClient *service.Client
	accountName   string
	containerName string
	// sharedKey is non-nil when authenticating via the account key; it is used
	// to sign service SAS URLs. When nil, user-delegation SAS is used instead.
	sharedKey *azblob.SharedKeyCredential
}

var _ StorageProvider = (*azureStorage)(nil)

type azureObject struct {
	client        *azblob.Client
	serviceClient *service.Client
	accountName   string
	containerName string
	path          string
}

var (
	_ Seekable = (*azureObject)(nil)
	_ Blob     = (*azureObject)(nil)
)

func newAzureStorage(ctx context.Context, containerName string) (*azureStorage, error) {
	account := os.Getenv(azureStorageAccountEnv)
	if account == "" {
		return nil, fmt.Errorf("%s must be set for the Azure storage provider", azureStorageAccountEnv)
	}

	serviceURL := fmt.Sprintf("https://%s.blob.core.windows.net/", account)

	// Prefer shared-key auth when AZURE_STORAGE_KEY is set (no RBAC needed);
	// otherwise fall back to the default credential chain (managed identity).
	if key := os.Getenv(azureStorageKeyEnv); key != "" {
		sharedKey, err := azblob.NewSharedKeyCredential(account, key)
		if err != nil {
			return nil, fmt.Errorf("failed to build Azure shared-key credential: %w", err)
		}
		client, err := azblob.NewClientWithSharedKeyCredential(serviceURL, sharedKey, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create Azure blob client: %w", err)
		} 

		return &azureStorage{
			client:        client,
			serviceClient: client.ServiceClient(),
			accountName:   account,
			containerName: containerName,
			sharedKey:     sharedKey,
		}, nil
	}

	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("failed to build Azure credential: %w", err)
	}

	client, err := azblob.NewClient(serviceURL, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create Azure blob client: %w", err)
	}

	return &azureStorage{
		client:        client,
		serviceClient: client.ServiceClient(),
		accountName:   account,
		containerName: containerName,
	}, nil
}

func (s *azureStorage) GetDetails() string {
	return fmt.Sprintf("[Azure Blob Storage, account %s, container %s]", s.accountName, s.containerName)
}

func (s *azureStorage) DeleteObjectsWithPrefix(ctx context.Context, prefix string) error {
	ctx, cancel := context.WithTimeout(ctx, azureWriteTimeout)
	defer cancel()

	containerClient := s.serviceClient.NewContainerClient(s.containerName)
	pager := containerClient.NewListBlobsFlatPager(&container.ListBlobsFlatOptions{Prefix: &prefix})

	deleted := 0
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("failed to list blobs with prefix %q: %w", prefix, err)
		}
		for _, item := range page.Segment.BlobItems {
			if item.Name == nil {
				continue
			}
			if _, err := s.client.DeleteBlob(ctx, s.containerName, *item.Name, nil); err != nil {
				if bloberror.HasCode(err, bloberror.BlobNotFound) {
					continue
				}
				return fmt.Errorf("failed to delete blob %q: %w", *item.Name, err)
			}
			deleted++
		}
	}

	if deleted == 0 {
		logger.L().Warn(ctx, "No objects found to delete with the given prefix",
			zap.String("prefix", prefix), zap.String("container", s.containerName))
	}

	return nil
}

// UploadSignedURL returns a short-lived user-delegation SAS URL granting
// create+write on the blob, so a client can PUT directly to Blob storage.
func (s *azureStorage) UploadSignedURL(ctx context.Context, path string, ttl time.Duration) (string, error) {
	now := time.Now().UTC().Add(-10 * time.Second) // small clock-skew allowance
	expiry := now.Add(ttl)

	values := sas.BlobSignatureValues{
		Protocol:      sas.ProtocolHTTPS,
		StartTime:     now,
		ExpiryTime:    expiry,
		Permissions:   (&sas.BlobPermissions{Create: true, Write: true}).String(),
		ContainerName: s.containerName,
		BlobName:      path,
	}

	var (
		qp  sas.QueryParameters
		err error
	)
	if s.sharedKey != nil {
		// Service SAS signed with the account key — no RBAC required.
		qp, err = values.SignWithSharedKey(s.sharedKey)
	} else {
		// User-delegation SAS (requires managed identity with a data role).
		info := service.KeyInfo{
			Start:  to.Ptr(now.UTC().Format(sas.TimeFormat)),
			Expiry: to.Ptr(expiry.UTC().Format(sas.TimeFormat)),
		}
		var udc *service.UserDelegationCredential
		udc, err = s.serviceClient.GetUserDelegationCredential(ctx, info, nil)
		if err != nil {
			return "", fmt.Errorf("failed to get user delegation credential: %w", err)
		}
		qp, err = values.SignWithUserDelegation(udc)
	}
	if err != nil {
		return "", fmt.Errorf("failed to sign SAS: %w", err)
	}

	return fmt.Sprintf("https://%s.blob.core.windows.net/%s/%s?%s",
		s.accountName, s.containerName, path, qp.Encode()), nil
}

func (s *azureStorage) OpenBlob(_ context.Context, path string) (Blob, error) {
	return s.newObject(path), nil
}

func (s *azureStorage) OpenSeekable(_ context.Context, path string) (Seekable, error) {
	return s.newObject(path), nil
}

func (s *azureStorage) newObject(path string) *azureObject {
	return &azureObject{
		client:        s.client,
		serviceClient: s.serviceClient,
		accountName:   s.accountName,
		containerName: s.containerName,
		path:          path,
	}
}

func (o *azureObject) blobClient() *blob.Client {
	return o.serviceClient.NewContainerClient(o.containerName).NewBlobClient(o.path)
}

func (o *azureObject) WriteTo(ctx context.Context, dst io.Writer) (n int64, err error) {
	start := time.Now()
	defer func() { RecordReadBlob(ctx, time.Since(start), n, o.path, SourceAzure, err) }()

	ctx, cancel := context.WithTimeout(ctx, azureReadTimeout)
	defer cancel()

	resp, err := o.client.DownloadStream(ctx, o.containerName, o.path, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return 0, ErrObjectNotExist
		}
		return 0, err
	}
	defer resp.Body.Close()

	n, err = io.Copy(dst, resp.Body)

	return n, err
}

func (o *azureObject) Put(ctx context.Context, data []byte, opts ...PutOption) error {
	ctx, cancel := context.WithTimeout(ctx, azureWriteTimeout)
	defer cancel()

	_, err := o.client.UploadBuffer(ctx, o.containerName, o.path, data, &azblob.UploadBufferOptions{
		Metadata: azureMetadata(ApplyPutOptions(opts).Metadata),
	})

	return err
}

func (o *azureObject) StoreFile(ctx context.Context, path string, opts ...PutOption) (*FullFrameTable, [32]byte, error) {
	p := ApplyPutOptions(opts)
	if CompressConfigFromOpts(p).IsCompressionEnabled() {
		return nil, [32]byte{}, errors.New("compressed uploads are not supported on Azure (builds target GCP only)")
	}

	// Inherit the caller's context for the whole chunked upload; the caller
	// scopes a per-attempt deadline with retry budget on top (matches AWS/GCP).
	f, err := os.Open(path)
	if err != nil {
		return nil, [32]byte{}, fmt.Errorf("failed to open file %s: %w", path, err)
	}
	defer f.Close()

	_, err = o.client.UploadFile(ctx, o.containerName, o.path, f, &azblob.UploadFileOptions{
		BlockSize:   10 * 1024 * 1024, // 10 MB blocks
		Concurrency: 8,                // eight blocks in flight
		Metadata:    azureMetadata(p.Metadata),
	})
	if err == nil {
		fi, _ := f.Stat()
		var size int64
		if fi != nil {
			size = fi.Size()
		}
		logger.L().Debug(ctx, "Uploaded file to Azure Blob",
			zap.String("container", o.containerName),
			zap.String("object", o.path),
			zap.String("source", path),
			zap.Int64("size_uncompressed", size),
			zap.String("compression", "none"),
		)
	}

	return nil, [32]byte{}, err
}

func (o *azureObject) OpenRangeReader(ctx context.Context, off, length int64, frameTable *FrameTable) (_ RangeReader, _ Source, err error) {
	start := time.Now()
	objType, _ := seekableObjectType(o.path)
	defer func() {
		RecordReadOpen(ctx, time.Since(start), objType, SourceAzure, frameTable.CompressionType(), err)
	}()

	if frameTable.IsCompressed() {
		return nil, SourceAzure, errors.New("compressed reads are not supported on Azure")
	}

	resp, err := o.client.DownloadStream(ctx, o.containerName, o.path, &azblob.DownloadStreamOptions{
		Range: blob.HTTPRange{Offset: off, Count: length},
	})
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return nil, SourceAzure, ErrObjectNotExist
		}
		return nil, SourceAzure, fmt.Errorf("failed to create Azure range reader for %q: %w", o.path, err)
	}

	return NewRangeReader(resp.Body), SourceAzure, nil
}

// Metadata implements MetadataReader: read the blob's custom metadata without
// downloading it, reversing the hyphen->underscore key sanitization applied on
// write (Azure Blob metadata names must be valid C# identifiers).
func (o *azureObject) Metadata(ctx context.Context) (ObjectMetadata, error) {
	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	resp, err := o.blobClient().GetProperties(ctx, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return nil, ErrObjectNotExist
		}
		return nil, err
	}

	out := make(ObjectMetadata, len(resp.Metadata))
	for k, v := range resp.Metadata {
		if v == nil {
			continue
		}
		out[azureUnsanitizeKey(k)] = *v
	}

	return out, nil
}

func (o *azureObject) Size(ctx context.Context) (_ int64, err error) {
	start := time.Now()
	objType, _ := seekableObjectType(o.path)
	defer func() { RecordReadSize(ctx, time.Since(start), objType, SourceAzure, err) }()

	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	resp, err := o.blobClient().GetProperties(ctx, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return 0, ErrObjectNotExist
		}
		return 0, err
	}
	if resp.ContentLength == nil {
		return 0, nil
	}

	return *resp.ContentLength, nil
}

func (o *azureObject) Exists(ctx context.Context) (bool, error) {
	_, err := o.Size(ctx)

	return err == nil, ignoreNotExists(err)
}

func (o *azureObject) Delete(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	_, err := o.client.DeleteBlob(ctx, o.containerName, o.path, nil)
	if bloberror.HasCode(err, bloberror.BlobNotFound) {
		return nil
	}

	return err
}

// azureMetadata converts the string map used by PutOptions into the
// map[string]*string that the Azure SDK expects. Azure Blob metadata names must
// be valid C# identifiers, so hyphens (used by keys like "logical-size" and
// "storage-index-soft-deleted") are rewritten to underscores — S3/GCS accept
// hyphens but Azure returns 400 InvalidMetadata. Metadata() reverses this.
func azureMetadata(m map[string]string) map[string]*string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]*string, len(m))
	for k, v := range m {
		out[azureSanitizeKey(k)] = to.Ptr(v)
	}

	return out
}

// azureSanitizeKey makes a metadata key a valid Azure Blob metadata name.
// Azure names must be valid C# identifiers (letters, digits, underscore; leading
// letter), so hyphens are encoded as a DOUBLE underscore. A single underscore is
// left as-is, so keys that already use underscores (team_id, template_id,
// build_origin) survive untouched. The encoding is reversible because no E2B
// metadata key contains a literal "__".
func azureSanitizeKey(k string) string {
	return strings.ReplaceAll(k, "-", "__")
}

func azureUnsanitizeKey(k string) string {
	return strings.ReplaceAll(k, "__", "-")
}
