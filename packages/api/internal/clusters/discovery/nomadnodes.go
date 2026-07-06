package discovery

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	nomadapi "github.com/hashicorp/nomad/api"
	"go.opentelemetry.io/otel/trace"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

// NomadNodesServiceDiscovery discovers template builders by listing Nomad
// *nodes* instead of Nomad *allocations*.
//
// It is used for deploys where the orchestrator binary (running both the
// orchestrator and template-manager services, see ORCHESTRATOR_SERVICES) is a
// systemd unit on every Nomad client node rather than a Nomad job — there are
// no template-manager allocations to find, but every ready node in the pool
// listens on consts.OrchestratorAPIPort. Whether an instance really is a
// template builder is still verified via its ServiceInfo roles during
// instance sync.
type NomadNodesServiceDiscovery struct {
	client    *nomadapi.Client
	clusterID uuid.UUID
	nodePool  string
}

// NewNomadNodesDiscovery wires a Nomad node-list-backed Discovery for the
// template builder pool inside the local cluster.
func NewNomadNodesDiscovery(clusterID uuid.UUID, client *nomadapi.Client, nodePool string) Discovery {
	return &NomadNodesServiceDiscovery{
		client:    client,
		clusterID: clusterID,
		nodePool:  nodePool,
	}
}

func (sd *NomadNodesServiceDiscovery) Query(ctx context.Context) ([]Item, error) {
	ctx, span := tracer.Start(ctx, "query-nomad-node-cluster-nodes", trace.WithAttributes(telemetry.WithClusterID(sd.clusterID)))
	defer span.End()

	options := &nomadapi.QueryOptions{
		Filter: fmt.Sprintf("Status == %q and NodePool == %q", "ready", sd.nodePool),
	}
	nodes, _, err := sd.client.Nodes().List(options.WithContext(ctx))
	if err != nil {
		span.RecordError(err)

		return nil, fmt.Errorf("failed to list Nomad nodes in template builder service discovery: %w", err)
	}

	out := make([]Item, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, Item{
			// Nomad node UUID is stable for the node's lifetime; using it keeps
			// the instance from being re-registered on every sync.
			UniqueIdentifier: n.ID,
			// Node name (the hostname / cloud instance name) mirrors the
			// allocation-based discovery, which uses alloc.NodeName.
			NodeID: n.Name,
			// InstanceID is "unknown" in the local-cluster path and will be
			// filled from ServiceInfo during instance sync.
			InstanceID: "unknown",

			LocalIPAddress:       n.Address,
			LocalInstanceApiPort: consts.OrchestratorAPIPort,
		})
	}

	return out, nil
}
