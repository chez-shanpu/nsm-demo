#!/usr/bin/env bash

cd "$(dirname "$0")"

#========= Setup Kubernetes Clusters =========
echo "Setup Kubernetes Clusters"

kind create cluster --config kind.yaml --name cluster1
kind create cluster --config kind.yaml --name cluster2

kind export kubeconfig --kubeconfig cluster1.yaml --name cluster1
kind export kubeconfig --kubeconfig cluster2.yaml --name cluster2

KUBECONFIG1=./cluster1.yaml
KUBECONFIG2=./cluster2.yaml

# note: these cidrs from `docker network inspect -f '{{$map := index .IPAM.Config 0}}{{index $map "Subnet"}}' kind`
CLUSTER1_CIDR=172.18.1.0/24
CLUSTER2_CIDR=172.18.2.0/24

#========== Deploy Loadbalancer ==========
echo "Deploy Loadbalancer"

if [[ ! -z $CLUSTER1_CIDR ]]; then
    kubectl --kubeconfig=$KUBECONFIG1 apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
    kubectl --kubeconfig=$KUBECONFIG1 apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/metallb.yaml
    cat > metallb-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $CLUSTER1_CIDR
EOF
    kubectl --kubeconfig=$KUBECONFIG1 apply -f metallb-config.yaml
    kubectl --kubeconfig=$KUBECONFIG1 wait --for=condition=ready --timeout=5m pod -l app=metallb -n metallb-system
fi

if [[ ! -z $CLUSTER2_CIDR ]]; then
    kubectl --kubeconfig=$KUBECONFIG2 apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
    kubectl --kubeconfig=$KUBECONFIG2 apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/metallb.yaml
    cat > metallb-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $CLUSTER2_CIDR
EOF
    kubectl --kubeconfig=$KUBECONFIG2 apply -f metallb-config.yaml
    kubectl --kubeconfig=$KUBECONFIG2 wait --for=condition=ready --timeout=5m pod -l app=metallb -n metallb-system
fi

#========== Setup DNS =========
echo "Setup DNS"

kubectl --kubeconfig=$KUBECONFIG1 expose service kube-dns -n kube-system --port=53 --target-port=53 --protocol=TCP --name=exposed-kube-dns --type=LoadBalancer

kubectl --kubeconfig=$KUBECONFIG1 get services exposed-kube-dns -n kube-system -o go-template='{{index (index (index (index .status "loadBalancer") "ingress") 0) "ip"}}'
ip1=$(kubectl --kubeconfig=$KUBECONFIG1 get services exposed-kube-dns -n kube-system -o go-template='{{index (index (index (index .status "loadBalancer") "ingress") 0) "ip"}}')
if [[ $ip1 == *"no value"* ]]; then
    ip1=$(kubectl --kubeconfig=$KUBECONFIG1 get services exposed-kube-dns -n kube-system -o go-template='{{index (index (index (index .status "loadBalancer") "ingress") 0) "hostname"}}')
    ip1=$(dig +short $ip1 | head -1)
fi
echo Selected externalIP: $ip1 for cluster1

kubectl --kubeconfig=$KUBECONFIG2 expose service kube-dns -n kube-system --port=53 --target-port=53 --protocol=TCP --name=exposed-kube-dns --type=LoadBalancer

kubectl --kubeconfig=$KUBECONFIG2 get services exposed-kube-dns -n kube-system -o go-template='{{index (index (index (index .status "loadBalancer") "ingress") 0) "ip"}}'
ip2=$(kubectl --kubeconfig=$KUBECONFIG2 get services exposed-kube-dns -n kube-system -o go-template='{{index (index (index (index .status "loadBalancer") "ingress") 0) "ip"}}')
if [[ $ip2 == *"no value"* ]]; then
    ip2=$(kubectl --kubeconfig=$KUBECONFIG2 get services exposed-kube-dns -n kube-system -o go-template='{{index (index (index (index .status "loadBalancer") "ingress") 0) "hostname"}}')
    ip2=$(dig +short $ip2 | head -1)
fi
echo Selected externalIP: $ip2 for cluster2

cat > configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        k8s_external my.cluster1
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        loop
        reload 5s
    }
    my.cluster2:53 {
      forward . ${ip2}:53 {
        force_tcp
      }
    }
EOF
kubectl --kubeconfig=$KUBECONFIG1 apply -f configmap.yaml
cat > custom-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  server.override: |
    k8s_external my.cluster2
  proxy1.server: |
    my.cluster2:53 {
      forward . ${ip2}:53 {
        force_tcp
      }
    }
EOF

kubectl --kubeconfig=$KUBECONFIG1 apply -f custom-configmap.yaml

cat > configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        k8s_external my.cluster2
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        loop
        reload 5s
    }
    my.cluster1:53 {
      forward . ${ip1}:53 {
        force_tcp
      }
    }
EOF
kubectl --kubeconfig=$KUBECONFIG2 apply -f configmap.yaml
cat > custom-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  server.override: |
    k8s_external my.cluster1
  proxy1.server: |
    my.cluster1:53 {
      forward . ${ip1}:53 {
        force_tcp
      }
    }
EOF

kubectl --kubeconfig=$KUBECONFIG2 apply -f custom-configmap.yaml

#========== Setup Spire ==========
echo "Setup Spire"

kubectl --kubeconfig=$KUBECONFIG1 apply -k https://github.com/networkservicemesh/deployments-k8s/examples/interdomain/spire/cluster1?ref=a84b670f19d8e40dd376d6bfc7550b436b90ae6b
kubectl --kubeconfig=$KUBECONFIG2 apply -k https://github.com/networkservicemesh/deployments-k8s/examples/interdomain/spire/cluster2?ref=a84b670f19d8e40dd376d6bfc7550b436b90ae6b

kubectl --kubeconfig=$KUBECONFIG1 wait -n spire --timeout=1m --for=condition=ready pod -l app=spire-agent
kubectl --kubeconfig=$KUBECONFIG1 wait -n spire --timeout=1m --for=condition=ready pod -l app=spire-server
kubectl --kubeconfig=$KUBECONFIG2 wait -n spire --timeout=1m --for=condition=ready pod -l app=spire-agent
kubectl --kubeconfig=$KUBECONFIG2 wait -n spire --timeout=1m --for=condition=ready pod -l app=spire-server

bundle1=$(kubectl --kubeconfig=$KUBECONFIG1 exec spire-server-0 -n spire -- bin/spire-server bundle show -format spiffe)
bundle2=$(kubectl --kubeconfig=$KUBECONFIG2 exec spire-server-0 -n spire -- bin/spire-server bundle show -format spiffe)

echo $bundle2 | kubectl --kubeconfig=$KUBECONFIG1 exec -i spire-server-0 -n spire -- bin/spire-server bundle set -format spiffe -id "spiffe://nsm.cluster2"
echo $bundle1 | kubectl --kubeconfig=$KUBECONFIG2 exec -i spire-server-0 -n spire -- bin/spire-server bundle set -format spiffe -id "spiffe://nsm.cluster1"

#========== Setup NSM ==========
echo "Setup NSM"
kubectl --kubeconfig=$KUBECONFIG1 apply -k https://github.com/networkservicemesh/deployments-k8s/examples/interdomain/nsm/cluster1?ref=a84b670f19d8e40dd376d6bfc7550b436b90ae6b
kubectl --kubeconfig=$KUBECONFIG2 apply -k https://github.com/networkservicemesh/deployments-k8s/examples/interdomain/nsm/cluster2?ref=a84b670f19d8e40dd376d6bfc7550b436b90ae6b

WH=$(kubectl --kubeconfig=$KUBECONFIG1 get pods -l app=admission-webhook-k8s -n nsm-system --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')
kubectl --kubeconfig=$KUBECONFIG1 wait --for=condition=ready --timeout=1m pod ${WH} -n nsm-system

WH=$(kubectl --kubeconfig=$KUBECONFIG2 get pods -l app=admission-webhook-k8s -n nsm-system --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')
kubectl --kubeconfig=$KUBECONFIG2 wait --for=condition=ready --timeout=1m pod ${WH} -n nsm-system

#========== Install Istio =========
echo "Install Istio"

curl -sL https://istio.io/downloadIstioctl | sh -
export PATH=$PATH:$HOME/.istioctl/bin
istioctl  install --set profile=minimal -y --kubeconfig=$KUBECONFIG2
istioctl --kubeconfig=$KUBECONFIG2 proxy-status

#========== Setup Demo Apps ==========
echo "Setup Demo Apps"

kubectl --kubeconfig=$KUBECONFIG2 apply -f https://raw.githubusercontent.com/networkservicemesh/deployments-k8s/a84b670f19d8e40dd376d6bfc7550b436b90ae6b/examples/interdomain/nsm_istio/networkservice.yaml
kubectl --kubeconfig=$KUBECONFIG1 apply -f https://raw.githubusercontent.com/networkservicemesh/deployments-k8s/a84b670f19d8e40dd376d6bfc7550b436b90ae6b/examples/interdomain/nsm_istio/greeting/client.yaml
kubectl --kubeconfig=$KUBECONFIG2 apply -k https://github.com/networkservicemesh/deployments-k8s/examples/interdomain/nsm_istio/nse-auto-scale?ref=a84b670f19d8e40dd376d6bfc7550b436b90ae6b

kubectl --kubeconfig=$KUBECONFIG2 label namespace default istio-injection=enabled

kubectl --kubeconfig=$KUBECONFIG2 apply -f https://raw.githubusercontent.com/networkservicemesh/deployments-k8s/a84b670f19d8e40dd376d6bfc7550b436b90ae6b/examples/interdomain/nsm_istio/greeting/server.yaml

kubectl --kubeconfig=$KUBECONFIG1 wait --timeout=2m --for=condition=ready pod -l app=alpine

kubectl --kubeconfig=$KUBECONFIG1 exec deploy/alpine -c cmd-nsc -- apk add curl

#========== Verify Connectivity ==========
echo "Verify Connectivity"
kubectl --kubeconfig=$KUBECONFIG1 exec deploy/alpine -c cmd-nsc -- curl -s greeting.default:9080 | grep -o "hello world from istio"
