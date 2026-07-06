package artifacts_registry

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

// Azure Container Registry (ACR) backend. Mirrors the AWS ECR backend: a single
// repository holds every template image, keyed by buildId as the tag. Auth uses
// the default Azure credential chain (managed identity on the node) exchanged
// for an ACR refresh token, which go-containerregistry then uses as basic auth.
type AzureArtifactsRegistry struct {
	loginServer    string // e.g. myregistry.azurecr.io
	repositoryName string
	cred           *azidentity.DefaultAzureCredential
	httpClient     *http.Client
}

var (
	// AzureLoginServerEnvVar is the ACR login server, e.g. "myregistry.azurecr.io".
	AzureLoginServerEnvVar = "AZURE_ACR_LOGIN_SERVER"
	// AzureRepositoryNameEnvVar is the repository within the registry.
	AzureRepositoryNameEnvVar = "AZURE_DOCKER_REPOSITORY_NAME"

	// AzureACRUsernameEnvVar / AzureACRPasswordEnvVar, when both set, use ACR
	// admin credentials (basic auth) instead of the AAD token exchange. This
	// avoids needing an AcrPull/AcrPush RBAC role assignment (Owner-only).
	AzureACRUsernameEnvVar = "AZURE_ACR_USERNAME"
	AzureACRPasswordEnvVar = "AZURE_ACR_PASSWORD"
)

func NewAzureArtifactsRegistry(_ context.Context) (*AzureArtifactsRegistry, error) {
	loginServer := os.Getenv(AzureLoginServerEnvVar)
	if loginServer == "" {
		return nil, fmt.Errorf("%s environment variable is not set", AzureLoginServerEnvVar)
	}
	repositoryName := os.Getenv(AzureRepositoryNameEnvVar)
	if repositoryName == "" {
		return nil, fmt.Errorf("%s environment variable is not set", AzureRepositoryNameEnvVar)
	}

	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("failed to build Azure credential: %w", err)
	}

	return &AzureArtifactsRegistry{
		loginServer:    loginServer,
		repositoryName: repositoryName,
		cred:           cred,
		httpClient:     &http.Client{Timeout: 15 * time.Second},
	}, nil
}

func (g *AzureArtifactsRegistry) GetTag(_ context.Context, _ string, buildId string) (string, error) {
	return fmt.Sprintf("%s/%s:%s", g.loginServer, g.repositoryName, buildId), nil
}

func (g *AzureArtifactsRegistry) GetImage(ctx context.Context, templateId string, buildId string, platform containerregistry.Platform) (containerregistry.Image, error) {
	imageUrl, err := g.GetTag(ctx, templateId, buildId)
	if err != nil {
		return nil, fmt.Errorf("failed to get image URL: %w", err)
	}

	ref, err := name.ParseReference(imageUrl)
	if err != nil {
		return nil, fmt.Errorf("invalid image reference: %w", err)
	}

	auth, err := g.getAuthToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get auth: %w", err)
	}

	img, err := remote.Image(ref, remote.WithAuth(auth), remote.WithPlatform(platform), remote.WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("error pulling image: %w", err)
	}

	return img, nil
}

// repoScope is the ACR OAuth scope granting pull+push+delete on the repository.
func (g *AzureArtifactsRegistry) repoScope() string {
	return fmt.Sprintf("repository:%s:pull,push,delete", g.repositoryName)
}

func (g *AzureArtifactsRegistry) Delete(ctx context.Context, templateId string, buildId string) error {
	imageUrl, err := g.GetTag(ctx, templateId, buildId)
	if err != nil {
		return fmt.Errorf("failed to get image URL: %w", err)
	}

	ref, err := name.ParseReference(imageUrl)
	if err != nil {
		return fmt.Errorf("invalid image reference: %w", err)
	}

	auth, err := g.getAuthToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get auth: %w", err)
	}

	// ACR (like most registries) deletes by digest, so resolve the tag first.
	desc, err := remote.Head(ref, remote.WithAuth(auth), remote.WithContext(ctx))
	if err != nil {
		if strings.Contains(err.Error(), "MANIFEST_UNKNOWN") || strings.Contains(err.Error(), "NAME_UNKNOWN") {
			return ErrImageNotExists
		}
		return fmt.Errorf("failed to resolve image digest: %w", err)
	}

	digestRef := ref.Context().Digest(desc.Digest.String())
	if err := remote.Delete(digestRef, remote.WithAuth(auth), remote.WithContext(ctx)); err != nil {
		return fmt.Errorf("failed to delete image from acr: %w", err)
	}

	return nil
}

// getAuthToken performs the full ACR token dance and returns a repository-scoped
// bearer authenticator that go-containerregistry can use directly:
//
//  1. AAD access token via the default credential chain (managed identity).
//  2. Exchange it at /oauth2/exchange for an ACR refresh token.
//  3. Exchange the refresh token at /oauth2/token for a repository-scoped
//     access token.
//
// Returning authn.Bearer (rather than basic auth with the refresh token) avoids
// relying on go-containerregistry's basic->bearer challenge matching ACR's
// refresh-token grant, which is the fragile path.
func (g *AzureArtifactsRegistry) getAuthToken(ctx context.Context) (authn.Authenticator, error) {
	// ACR admin credentials (basic auth) — no RBAC role assignment required.
	if user := os.Getenv(AzureACRUsernameEnvVar); user != "" {
		if pass := os.Getenv(AzureACRPasswordEnvVar); pass != "" {
			return &authn.Basic{Username: user, Password: pass}, nil
		}
	}

	refreshToken, err := g.getRefreshToken(ctx)
	if err != nil {
		return nil, err
	}

	accessToken, err := g.getAccessToken(ctx, refreshToken, g.repoScope())
	if err != nil {
		return nil, err
	}

	return &authn.Bearer{Token: accessToken}, nil
}

// getRefreshToken exchanges an AAD token for an ACR refresh token.
func (g *AzureArtifactsRegistry) getRefreshToken(ctx context.Context) (string, error) {
	aadToken, err := g.cred.GetToken(ctx, policy.TokenRequestOptions{
		// ARM-scoped AAD token; ACR's exchange endpoint accepts it.
		Scopes: []string{"https://management.azure.com/.default"},
	})
	if err != nil {
		return "", fmt.Errorf("failed to acquire AAD token: %w", err)
	}

	form := url.Values{}
	form.Set("grant_type", "access_token")
	form.Set("service", g.loginServer)
	form.Set("access_token", aadToken.Token)

	var body struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := g.postForm(ctx, "/oauth2/exchange", form, &body); err != nil {
		return "", fmt.Errorf("acr refresh-token exchange failed: %w", err)
	}
	if body.RefreshToken == "" {
		return "", fmt.Errorf("acr token exchange returned an empty refresh token")
	}

	return body.RefreshToken, nil
}

// getAccessToken exchanges a refresh token for a scoped ACR access token.
func (g *AzureArtifactsRegistry) getAccessToken(ctx context.Context, refreshToken, scope string) (string, error) {
	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("service", g.loginServer)
	form.Set("scope", scope)
	form.Set("refresh_token", refreshToken)

	var body struct {
		AccessToken string `json:"access_token"`
	}
	if err := g.postForm(ctx, "/oauth2/token", form, &body); err != nil {
		return "", fmt.Errorf("acr access-token exchange failed: %w", err)
	}
	if body.AccessToken == "" {
		return "", fmt.Errorf("acr token exchange returned an empty access token")
	}

	return body.AccessToken, nil
}

// postForm POSTs a urlencoded form to an ACR oauth2 endpoint and decodes JSON.
func (g *AzureArtifactsRegistry) postForm(ctx context.Context, path string, form url.Values, out any) error {
	endpoint := fmt.Sprintf("https://%s%s", g.loginServer, path)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := g.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("request to %s failed: %w", path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s returned status %d", path, resp.StatusCode)
	}

	return json.NewDecoder(resp.Body).Decode(out)
}
