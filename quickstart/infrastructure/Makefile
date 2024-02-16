.PHONY: all init deploy plan destroy fmt clean
.PHONY: consul consul-info consul-use1 consul-usw2 awslb dataplane fake-service

OUTPUT=`terraform output -raw`

all: infra consul fake-service apigw-install consul-peering
clean: 
infra: fmt
	@terraform init
	@-terraform apply -auto-approve
fmt:
	@terraform fmt -recursive

consul: awslb consul-install
awslb:
	@../../scripts/install_awslb_controller.sh .
consul-install:
	@-terraform -chdir="consul_helm_values" apply -auto-approve

apigw-install:
	@source "../../scripts/kubectl_connect_eks.sh" .
	@kubectl config use-context usw2
	@kubectl apply -f ../../examples/consul-apigw/
	@echo
	@echo "USW2 - API Gateway URL:"
	@-echo "https://`kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`"
	@echo
	@kubectl config use-context use1
	@kubectl apply -f ../../examples/consul-apigw/
	@echo
	@echo "USE1 - API Gateway URL:"
	@-echo "https://`kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`"
	@echo

fake-service: usw2-install use1-install
usw2-install:
	@source "../../scripts/kubectl_connect_eks.sh" .
	@kubectl config use-context usw2
	@-../../examples/fake-service/web/deploy.sh
	@-../../examples/fake-service/api/deploy.sh
use1-install:
	@source "../../scripts/kubectl_connect_eks.sh" .
	@kubectl config use-context use1
	@-../../examples/fake-service/web/deploy.sh
	@-../../examples/fake-service/api/deploy.sh

consul-clean: fake-service-clean consul-uninstall
fake-service-clean: usw2-clean
usw2-clean:
	@source "../../scripts/kubectl_connect_eks.sh" .
	@kubectl config use-context usw2
	@-../../examples/fake-service/web/deploy.sh -d
	@-../../examples/fake-service/api/deploy.sh -d
	@-../../examples/fake-service/payments/deploy.sh -d
	@-kubectl delete -f ../../examples/fake-service/api/api-v3.yaml.enable
	@-kubectl delete -f ../../examples/fake-service/api/init-consul-config/serviceRouter-retries.yaml.enable
	@-kubectl delete -f ../../examples/consul-apigw/

consul-uninstall:
	@-terraform -chdir="consul_helm_values" destroy -auto-approve
	@-helm uninstall -n kube-system aws-load-balancer-controller

infra-clean:
	@-terraform destroy -auto-approve