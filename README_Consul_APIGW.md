# Deploy the Consul API Gateway
Authenticate to the EKS cluster and ensure you are on the context (ex: usw2) you want to deploy the api-gateway to.  The command below will do the following:
* Deploy Gateway to listen on port 80
* Set annotations to support AWS LB Controller
* The *ClusterRole* and *ClusterRoleBindings* allow the apigw to interact with Consul resources.
* Configure HTTP routes for services in the mesh (`web`).

| Filename                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| consul-apigw.yaml                          | Create Gateway, ClusterRoles, and ClusterRoleBindings|
| apigw-ReferenceGrant.yaml                  | Example only, Every ns that requires access to the AIP GW needs a ReferenceGrant including default|
| apigw-RouteTimeoutFilter.yaml.enable       | Example only, Defined per route `./web/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable`|

```
kubectl apply -f examples/consul-apigw/
```

## Get apigw URL
```
export APIGW_URL=$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
nslookup ${APIGW_URL}
###   WARNING: Wait for the external DNS name to be resolvable
```

## Deploy web
[fake-service](https://github.com/nicholasjackson/fake-service) can handle both HTTP and gRPC traffic, for testing service mesh communication scenarios. Using fake-service deploy the first service into the service mesh called `web`
```
cd ./examples/fake-service-community
```

Apply the following files into the web namespace
| Filename                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| web/init-consul-config/ReferenceGrant.yaml     | Allow the API Gateway access to the k8s namespace running `web`|
| web/init-consul-config/apigw-route-web.yaml    | Define HTTPRoute's from the API Gateway to services|
| web/init-consul-config/servicedefaults.yaml    | Set service level configurations like the protocol (http)|
| web/init-consul-config/sg-intentions.yaml      | AuthZ rule or **intention** allowing `web` to talk to `api`|
| web/init-consul-config/sg-exportedServices.yaml| list of services that should be discoverable from remote data centers|
| web/init-consul-config/proxydefaults.yaml      | Configure all proxies to use local meshGateways when routing across Peers|
| web/init-consul-config/mesh.yaml               | Configure Peering and allow mesh services external access|
| web/web-v1.yaml                                | Create K8s ServiceAccount, Service, and `web` Deployment.  Using annotation **connect-inject** to enable service mesh|

```
kubectl create ns web
kubectl apply -f web/init-consul-config
kubectl apply -f web/web-v1.yaml
```

## Access web using the HTTP routes defined in apigw-route-web.yaml
```
echo "http://${APIGW_URL}/ui"
echo "http://${APIGW_URL}/"
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