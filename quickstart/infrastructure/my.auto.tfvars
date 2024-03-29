prefix                     = "presto-mig"
ec2_key_pair_name          = "ppresto-ptfe-dev-key"
eks_cluster_version        = "1.28"
min_consul_version         = "1.17.3" #Version used when deploying HCP Consul
consul_version             = "1.17.3" # Version used in helm values for dataplane and self-hosted setups
consul_helm_chart_version  = "1.3.2"
consul_helm_chart_template = "values-server-sm-apigw.yaml"
#consul_helm_chart_template = "values-server.yaml"
#consul_helm_chart_template = "values-dataplane.yaml"
consul_partition = "default"