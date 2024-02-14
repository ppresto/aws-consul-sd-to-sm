# aws-consul-pd
Setup the Consul API Gateway (apigw) with fake-service to access services inside the service mesh.

## Quick Start
### Deploy services
The fake-service can be configured as any service and can route requests to any number of other upstreams. 
* Deploy 2 services (web, api) into the Consul service mesh, and each will run in their own K8s namespace.  
* fake-service `web` will be configured to route to `api`.
* Create Consul intentions to authorize `web` to route requests to `api`.

```
cd ./examples
./fake-service/web/deploy.sh
./fake-service/api/deploy.sh
```

### Deploy the Consul apigw
Authenticate to the EKS cluster and ensure you are on the context (ex: usw2) you want to deploy the api-gateway to.
* Deploy Gateway to listen on port 80
* Set annotations to support AWS LB Controller
* Create RBACs so the API gateway can interact with Consul resources
* Configure HTTP routes for services in the mesh (`web`, `api`).

```
kubectl apply -f consul-apigw/
```

### Get apigw URL
```
export APIGW_URL=$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
nslookup ${APIGW_URL}
###   WARNING: Wait for the external DNS name to be resolvable
```

### Access the services using the HTTP routes defined in the apigw
```
echo "http://${APIGW_URL}/ui"
echo "http://${APIGW_URL}/"
echo "http://${APIGW_URL}/api"
```

## Manual Steps
### Deploy web svc
Using fake-service deploy the first service into the service mesh called `web`
```
cd ./examples/fake-service
```

Create a K8s namespace for `web`
```
kubectl create ns web
```

Use kubeclt to apply the following files. If using **samenessGroups** apply them first so dependent resources can use them.
| Filename                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| web/init-consul-config/ReferenceGrant.yaml     | Allow the API Gateway access to the k8s namespace running `web`|
| web/init-consul-config/apigw-route-web.yaml    | Define HTTPRoute's from the API Gateway to services|
| web/init-consul-config/servicedefaults.yaml    | Set service level configurations like the protocol (http)|
| web/init-consul-config/sg-samenessGroup.yaml   | Sameness groups(sg) are a Svc abstraction used to group AuthZ rules, and failover policies|
| web/init-consul-config/sg-intentions.yaml      | AuthZ rule or **intention** allowing `web` to talk to `api`|
| web/init-consul-config/sg-exportedServices.yaml| list of services that should be discoverable from remote data centers|
| web/init-consul-config/mesh.yaml               | Required when Peering Consul data centers using local Mesh Gateways (Best Practices)|
| web/init-consul-config/proxydefaults.yaml      | Configure all proxies to use local meshGateways when routing across Peers|
| web/web.yaml                                   | Create K8s ServiceAccount, Service, and `web` Deployment into Consul service mesh|

Note: Sameness groups are not required if services have no failover or distributed requirements.  AuthZ rules are configured using intentions and these can be created without sg for example `init-consul-config/intenations-web.yaml.dis`.

#### Sameness Groups Overview
Use sameness groups when deploying services to minimize service configuration and provide failover at the same time. A sameness group allows a service or group of services to be configured together. A sameness group consists of the following:
* SamenessGroup - Define the remote Peers or Partitions the should be used for HA/failover when the local services is unavailable.
* Intentions - authorize service to service requests both locally and from remote data centers.
* ExportedServices - The list of services allowed to be discovered from outside the local data center

### Deploy api svc
Repeat these steps above for `api` to have a second service deployed into the mesh with different http routes.
* Create namespace `api`
* Apply api/init-consul-config/
* Apply api/api-v1.yaml api-v2.yaml

### Deploy API Gateway
```
cd ../consul-apigw
kubectl apply -f consul-apigw.yaml
```
Create a *Gateway* resource that listens to HTTP traffic on port 80.  The *ClusterRole* and *ClusterRoleBindings* allow the Consul API gateway to interact with Consul resources.

| Filename                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| apigw-ReferenceGrant.yaml                  | Example only, Every ns that requires access to the AIP GW needs a ReferenceGrant|
| apigw-RouteTimeoutFilter.yaml.enable       | Example only, Defined per route `./web/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable`|

### Get API Gateway URL
```
export APIGW_URL=$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
nslookup ${APIGW_URL}
###   WARNING: Wait for the external DNS name to be resolvable
```

### Debug API Gateway Config
```
kubectl debug -it -n consul $(kubectl -n consul get pods -l gateway.consul.hashicorp.com/name=api-gateway --output jsonpath='{.items[0].metadata.name}') --target api-gateway --image nicolaka/netshoot -- curl localhost:19000/config_dump\?include_eds | code -
```


## Clean up
```
kubectl delete -f consul-apigw/
./fake-service/web/deploy.sh -d
./fake-service/api/deploy.sh -d

```