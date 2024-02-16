# Deploy the Consul API Gateway
Authenticate to the EKS cluster and ensure you are on the context (ex: usw2) you want to deploy the api-gateway to.
* Deploy Gateway to listen on port 80
* Set annotations to support AWS LB Controller
* Create RBACs so the API gateway can interact with Consul resources
* Configure HTTP routes for services in the mesh (`web`).

```
kubectl apply -f examples/consul-apigw/
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
```

## Manual Steps
### Deploy web svc
Using fake-service deploy the first service into the service mesh called `web`
```
cd ./examples/fake-service-community
```

Create a K8s namespace for `web`
```
kubectl create ns web
```

Use kubeclt to apply the following files. 
| Filename                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| web/init-consul-config/ReferenceGrant.yaml     | Allow the API Gateway access to the k8s namespace running `web`|
| web/init-consul-config/apigw-route-web.yaml    | Define HTTPRoute's from the API Gateway to services|
| web/init-consul-config/servicedefaults.yaml    | Set service level configurations like the protocol (http)|
| web/init-consul-config/sg-intentions.yaml      | AuthZ rule or **intention** allowing `web` to talk to `api`|
| web/init-consul-config/sg-exportedServices.yaml| list of services that should be discoverable from remote data centers|
| web/init-consul-config/proxydefaults.yaml      | Configure all proxies to use local meshGateways when routing across Peers|
| web/init-consul-config/mesh.yaml               | Configure Peering and allow mesh services external access|
| web/web.yaml                                   | Create K8s ServiceAccount, Service, and `web` Deployment into Consul service mesh|

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
./fake-service-community/web/deploy.sh -d
kubectl delete -f consul-apigw/
```