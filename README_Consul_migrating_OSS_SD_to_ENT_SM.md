# Migrating from OSS Consul SD on EKS to ENT Consul Service Mesh
![ServiceDicovery_to_ServiceMesh](https://github.com/ppresto/aws-consul-pd/blob/main/migration_sd_to_sm.png?raw=true)
Deploy Consul-Ent on EKS to have existing services hosted in the default partition and default namespace (default/default) to mirror the existing Community edition. This allows all services to use the current default service discovery over HTTP and adopt service mesh.

Once running in this hybrid mode, allow services to update their DNS names to use new service mesh virtual addresses on their own schedule.  While this is happening, in the background enforce mTLS connections to encrypt all east/west traffic. Once all downstream services have updated their DNS to use the new service mesh virtual addresses, disable service discovery.  At this point all services are running in default/default and using mTLS to secure all traffic.  Allow service teams or other organizations to adopt Consul partitions or namespaces for additional security, segmentation, and self service capabilities.

## PreReq
* Install Consul-Ent on EKS with [helm.values](https://github.com/ppresto/aws-consul-pd/blob/main/quickstart/2vpc-2eks-multiregion/consul_helm_values/yaml/example-oss-sd-to-ent-sm-apigw-ap-ns.yaml) to enable catalog-sync, DNS forwarding, connect-inject, apigw, namespaces, and admin partition support. Mirror Community design by having all K8s services use their own K8s namespace, but use Consul's default partion and namespace.  Ensure this is setup for both catalog-sync and connect-inject and verify helm values before applying to your EKS cluster.
    ```
    usw2  # alias for K8s context

    consul-k8s upgrade -f ./quickstart/2vpc-2eks-multiregion/consul_helm_values/yaml/example-oss-sd-to-ent-sm-apigw-ap-ns.yaml
    ```
* Consul API Gateway configured
    ```
    kubectl apply -f ./examples/consul-apigw/
    ```
* fake-services-OSS are deployed and healthy
    ```
    usw2
    cd ./examples
    ./fake-service-OSS/web/deploy.sh
    ./fake-service-OSS/api/deploy.sh
    ```
* verify API Gateway Ingress ( web [*service mesh enabled*] -> api [*no mesh*])
    ```
    kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    ```

## Onboard existing services to mesh using permissive mTLS mode
Enable existing services to participate in the service mesh and support service discovery (mTLS and HTTP) by enabling **permissive mTLS**.  Once all downstreams are onboarded into the mesh disable permissive mTLS for the upstream service to ensure all requests are secure and encrypted.  

Apply new mesh defaults to allow for permissive mTLS mode.  Only 1 mesh-defaults configuration is allowed per Consul data center.
```
kubectl apply -f ./fake-service-OSS/api/permissive_mTLS_mode/mesh.yaml
```

Next, apply permissive mode for the upstream service `api` and bootstrap it into the service mesh.
```
kubectl apply -f ./fake-service-OSS/api/permissive_mTLS_mode/servicedefaults-permissive.yaml
kubectl apply -f ./fake-service-OSS/api/permissive_mTLS_mode/api-v1-connect-inject.yaml
```
`Note:` Downstream services are required to update DNS from *example.service.consul* to the new virtual lookup *example.virtual.consul* or kubedns before they can take full advantage of all HTTP traffic management capabilities.

### Verify existing Service Discovery FQDN's route to newly SM/SD enabled service
`web` is calling the upstream service `api` using the original service discovery address *api.service.consul* acting like any other service not inside the service mesh.  This request will be over HTTP and not using any mTLS. Verify the `web` container is directly accessing the `api` pod on port **9091** and not using the `api` sidecar proxy.
```
kubectl debug -it -n api $(kubectl -n api get pods --output jsonpath='{.items[0].metadata.name}') --target consul-dataplane --image nicolaka/netshoot -- tcpdump -i eth0 src port 9091 -A
```
Generate a request using curl or the browser and verify it returns a successful 200. use tcpdump on the pod to verify the request is unencrypted and going directly to the service port **9091**.

### Enforce mTLS connections for existing services using the original Service Discovery FQDN

Once all downstream services are onboarded into the mesh or the API gateway is configured to route requests from non-mesh services there is no requirement for the upstream service to support HTTP.  Disable permissive mTLS by setting `mutualTLSMode: "strict"`.  To allow downstream services to use the same Service Discovery FQDN with mTLS set `dialedDirectly: true`. This will properly route requests targeting the Pod_IP by using a TCP passthrough.  Here is an example service defaults:

```./fake-service-OSS/api/permissive_mTLS_mode/servicedefaults-strict-dialDirect.yaml.enable
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: api
  namespace: api
spec:
  protocol: http
  mutualTLSMode: "strict"  #Disables permissive mTLS
  transparentProxy: 
    dialedDirectly: true
```
**NOTE:** This TCP configuration doesn't support HTTP Filters or load balancing.  These features are only available to downstream services that use the new virtual address (*api.virtual.consul*) instead of the original SD FQDN (*api.service.consul*).


Apply the config
```
kubectl apply -f ./fake-service-OSS/api/permissive_mTLS_mode/servicedefaults-strict-dialDirect.yaml.enable
```

Verify `web` can still access `api` using the same SD FQDN *api.service.consul*.  This time traffic will be routed through the sidecar proxies enforcing an mTLS connection.
```
kubectl debug -it -n api $(kubectl -n api get pods --output jsonpath='{.items[0].metadata.name}') --target consul-dataplane --image nicolaka/netshoot -- tcpdump -i eth0 src port 9091 -A
```
Using **dialDirectly** all downstream services are supporting mTLS without any application configuration changes required. 

### Update downstream requests to use the virtual address
Now that services are secure its a good time to have downstream services update their upstream requests to use the new virtual address that is supported by the service mesh instead of the legacy service discovery lookup that goes directly to the Pod_IP.  Using the virtual address allows downstream services to take advantage of all the L7 traffic features an upstream might have configured like retires, rate limits, timeouts, circuit breakers, etc...

```
kubectl apply -f ./fake-service-OSS/api/permissive_mTLS_mode/web-virtualaddress.yaml.enable
```
If the virtual address is used, all traffic should be using the envoy port (no dialDirect to the pod IP:Port).  

Verify traffic is encrypted and using the default envoy port 20000.
```
kubectl debug -it -n api $(kubectl -n api get pods --output jsonpath='{.items[0].metadata.name}') --target consul-dataplane --image nicolaka/netshoot -- tcpdump -i eth0 src port 20000 -A
```
The previous tcpdump test command monitors traffic over port 9091.  This port should no longer be getting requests. 

### Remove Permissive mode in service defaults and the mesh-default
Once all services are onboarded into the mesh and using the Consul virtual addresses there is no need for DialDirectly and Permissive modes to be available.
```
kubectl apply -f ./fake-service-OSS/api/init-consul-config/servicedefaults.yaml
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/mesh.yaml
kubectl apply -f ./fake-service-OSS/web/init-consul-config/mesh.yaml.disable
```

## Migrate services to a new Partition/Namespace
If migrating from OSS, services may not be using namespaces or partitions.  If supporting a multi-tenant environment there may be requirements for services or organizations to eventually have their own namespace or partition.  This requires a service to be moved to the new location (peer/partition/namespace).  To do this without impacting existing downstream services a **Service Resolver** can be used to redirect requests from the old location to a new. The example below shows how to migrate a service from the default namespace to a new ENT namespace.

### Enable a new Partition on a new K8s cluster
To incrementally migrate applications to ENT partitions/namespaces without impacting downstreams bootstrap a 2nd K8s cluster to Consul (operating as a dataplane only) that supports Partitions and Namespaces.  Here are commands to quickly pull required server info for bootstrapping the new dataplane Partition to Consul using this repo.
```
# Update `hcp_consul_ca_file` in ./quickstart/2vpc-2eks-multiregion/consul_helm_values/${cluster}.tf 
# use base64 data
kubectl -n consul get secret consul-ca-cert --context usw2 -o json | jq -r '.data."tls.crt"'

# Update `hcp_consul_root_token_secret_id` in ./quickstart/2vpc-2eks-multiregion/consul_helm_values/${cluster}.tf 
kubectl -n consul get secret consul-bootstrap-acl-token --context usw2 --template "{{.data.token | base64decode}}"

# Update `consul_external_servers` in ./quickstart/2vpc-2eks-multiregion/consul_helm_values/${cluster}.tf 
kubectl -n consul get svc consul-expose-servers --context usw2 -o json | jq -r '.status.loadBalancer.ingress[].hostname'
```

Bootstrap the second K8s cluster to a new Consul partition by running TF.
```
cd ./quickstart/2vpc-2eks-multiregion/consul_helm_values/
terraform apply -auto-approve -target module.consul_pagerduty-shared-usw2new
```

### Deploy `api` to the new K8s cluster
This will deploy the same services to the new cluster with additional intentions.  
```
usw2new #alias to new K8s context
./namespace_migration/shared/api/deploy.sh
./namespace_migration/shared/web/deploy.sh
```
Sameness groups are designed to work in this failover use case.  They need further investigation...  Until then, we are manually defining a resolver.

### Create a service-resolver in default/default to route traffic to shared/api
The `api` service was just deployed to shared/api.  Now traffic from all downstreams that are unaware of this change needs to be redirected to it. build a service resolver failover target in the default partition and namespace. 
```
usw2
kubectl apply -f ./namespace_migration/default/api_serviceResolver_failover.yaml
```

Now all downstream requests to the default namespace for `api` (**api.virtual.consul**) can failover to **api.virtual.shared.ap.api.ns.consul** requiring no downstream changes.  Test this by undeploying the `api` svc in default/default to use the new one deployed in shared/api.
```
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/api-v1-connect-inject.yaml
```
web should now automatically be routed to shared/api.


**Note**: In Consul 1.17.1 redirects don't appear to be supported across partitions: `./namespace_migration/default/api_serviceResolver_redirect.yaml`
```
Unexpected response code: 500 (peer exported service "default/default/api" contains cross-partition resolver redirect
```

### Migrate a service with API Gateway routes to a new partition/namespace

...

## Clean up
```
usw2
kubectl delete -f ./namespace_migration/default/api_serviceResolver_failover.yaml
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/web-virtualaddress.yaml.enable
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/api-v1-connect-inject.yaml
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/servicedefaults-strict-dialDirect.yaml.enable
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode
kubectl delete -f ./fake-service-OSS/api/
kubectl delete -f ./fake-service-OSS/api/init-consul-config/
kubectl delete -f ./fake-service-OSS/web/
kubectl delete -f ./fake-service-OSS/web/init-consul-config/
kubectl delete -f ./fake-service-OSS/web/init-consul-config/mesh.yaml.disable

usw2new
kubectl delete -f ./namespace_migration/shared/api/
kubectl delete -f ./namespace_migration/shared/api/init-consul-config/
kubectl delete -f ./namespace_migration/shared/web/
kubectl delete -f ./namespace_migration/shared/web/init-consul-config/
usw2
```