# k8s-prom-hpa

Autoscaling is an approach to automatically scale up or down workloads based on the resource usage. 
Autoscaling in Kubernetes has two dimensions: the Cluster Autoscaler that deals with node scaling 
operations and the Horizontal Pod Autoscaler that automatically scales the number of pods in a 
deployment or replica set. The Cluster Autoscaling together with Horizontal Pod Autoscaler can be used 
to dynamically adjust the computing power as well as the level of parallelism that your system needs to meet SLAs.
While the Cluster Autoscaler is highly dependent on the underling capabilities of the cloud provider 
that's hosting your cluster, the HPA can operate independently of your IaaS/PaaS provider. 

The Horizontal Pod Autoscaler feature was first introduced in Kubernetes v1.1 and 
has evolved a lot since then. Version 1 of the HPA scaled pods based on 
observed CPU utilization and later on based on memory usage. 
In Kubernetes 1.6 a new API Custom Metrics API was introduced that enables HPA access to arbitrary metrics. 
And Kubernetes 1.7 introduced the aggregation layer that allows 3rd party applications to extend the 
Kubernetes API by registering themselves as API add-ons. 
The Custom Metrics API along with the aggregation layer made it possible for lstack-system systems 
like Prometheus to expose application-specific metrics to the HPA controller.

The Horizontal Pod Autoscaler is implemented as a control loop that periodically queries 
the Resource Metrics API for core metrics like CPU/memory and the Custom Metrics API for application-specific metrics.  

![Overview](https://github.com/stefanprodan/k8s-prom-hpa/blob/master/diagrams/k8s-hpa.png)

What follows is a step-by-step guide on configuring HPA v2 for Kubernetes 1.9 or later. 
You will install the Metrics Server add-on that supplies the core metrics and then you'll use a demo 
app to showcase pod autoscaling based on CPU and memory usage. In the second part of the guide you will 
deploy Prometheus and a custom API server. You will register the custom API server with the 
aggregator layer and then configure HPA with custom metrics supplied by the demo application.

Before you begin you need to install Go 1.8 or later and clone the [k8s-prom-hpa](https://github.com/stefanprodan/k8s-prom-hpa) repo in your `GOPATH`:

```bash
cd $GOPATH
git clone https://github.com/xishengcai/k8s-prom-hpa
sh genert-cert.sh
```

### Setting up the Metrics Server

The Kubernetes [Metrics Server](https://github.com/kubernetes-incubator/metrics-server) 
is a cluster-wide aggregator of resource usage data and is the successor of [Heapster](https://github.com/kubernetes/heapster). 
The metrics server collects CPU and memory usage for nodes and pods by pooling data from the `kubernetes.summary_api`. 
The summary API is a memory-efficient API for passing data from Kubelet/cAdvisor to the metrics server.

![Metrics-Server](https://github.com/stefanprodan/k8s-prom-hpa/blob/master/diagrams/k8s-hpa-ms.png)

If in the first version of HPA you would need Heapster to provide CPU and memory metrics, in 
HPA v2 and Kubernetes 1.8 only the metrics server is required with the 
`horizontal-pod-autoscaler-use-rest-clients` switched on.
The HPA rest client is enabled by default in Kubernetes 1.9.
GKE 1.9 comes with the Metrics Server pre-installed.

Deploy the Metrics Server in the `kube-system` namespace:

```bash
kubectl create -f ./metrics-server
```

After one minute the `metric-server` starts reporting CPU and memory usage for nodes and pods.

View nodes metrics:

```bash
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes" | jq .
```

View pods metrics:

```bash
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/pods" | jq .
```

### Setting up a Custom Metrics Server 

In order to scale based on custom metrics you need to have two components. 
One component that collects metrics from your applications and stores them the [Prometheus](https://prometheus.io) time series database.
And a second component that extends the Kubernetes custom metrics API with the metrics supplied by the collect, the [k8s-prometheus-adapter](https://github.com/DirectXMan12/k8s-prometheus-adapter).

![Custom-Metrics-Server](https://github.com/stefanprodan/k8s-prom-hpa/blob/master/diagrams/k8s-hpa-prom.png)

You will deploy Prometheus and the adapter in a dedicated namespace. 

Create the `lstack-system` namespace:

```bash
kubectl create -f ./namespaces.yaml
```

Deploy the Prometheus custom metrics API adapter:

```bash
kubectl create -f ./custom-metrics-api
```

List the custom metrics provided by Prometheus:

```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq .
```

Get the http_request for all the pods in the `lstack-system` namespace:

```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/services/*/istio_requests_per_min" | jq .
```
```json
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta1",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/services/%2A/istio_requests_per_min"
  },
  "items": [
    {
      "describedObject": {
        "kind": "Service",
        "namespace": "default",
        "name": "details",
        "apiVersion": "/v1"
      },
      "metricName": "istio_requests_per_min",
      "timestamp": "2020-12-23T03:43:00Z",
      "value": "133333m"
    },
    {
      "describedObject": {
        "kind": "Service",
        "namespace": "default",
        "name": "productpage",
        "apiVersion": "/v1"
      },
      "metricName": "istio_requests_per_min",
      "timestamp": "2020-12-23T03:43:00Z",
      "value": "0"
    },
    {
      "describedObject": {
        "kind": "Service",
        "namespace": "default",
        "name": "reviews",
        "apiVersion": "/v1"
      },
      "metricName": "istio_requests_per_min",
      "timestamp": "2020-12-23T03:43:00Z",
      "value": "0"
    }
  ]
}
```


Deploy the `productpage` HPA in the `default` namespace:

```bash
kubectl create -f istio-hpa.yaml
```

After a couple of seconds the HPA fetches the `http_requests` value from the metrics API:

```bash
kubectl get hpa
```
```
NAME                      REFERENCE                   TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
productpage-obj-service   Deployment/productpage-v1   133333m/100   1         2         1          11h
```

Apply some load on the `productpage` service with 25 requests per second:

```bash
#install hey
go get -u github.com/rakyll/hey

#do 10K requests rate limited at 25 QPS
hey -n 1000 -q 5 -c 5 http://<K8S-IP>:31198/productpage
```

After a few minutes the HPA begins to scale up the deployment:

```
kubectl describe hpa

^CXishengdeMacBook-Pro:~ xishengcai$ kubectl describe hpa productpage-obj-service
Name:                                                              productpage-obj-service
Namespace:                                                         default
Labels:                                                            <none>
Annotations:                                                       kubectl.kubernetes.io/last-applied-configuration:
                                                                     {"apiVersion":"autoscaling/v2beta1","kind":"HorizontalPodAutoscaler","metadata":{"annotations":{},"name":"productpage-obj-service","namesp...
CreationTimestamp:                                                 Wed, 23 Dec 2020 00:23:29 +0800
Reference:                                                         Deployment/productpage-v1
Metrics:                                                           ( current / target )
  "istio_requests_per_min" on service/productpage (target value):  0 / 100
Min replicas:                                                      1
Max replicas:                                                      2
Deployment pods:                                                   2 current / 2 desired
Conditions:
  Type            Status  Reason               Message
  ----            ------  ------               -------
  AbleToScale     True    ScaleDownStabilized  recent recommendations were higher than current one, applying the highest recent recommendation
  ScalingActive   True    ValidMetricFound     the HPA was able to successfully calculate a replica count from service metric istio_requests_per_min
  ScalingLimited  True    TooManyReplicas      the desired replica count is more than the maximum replica count
Events:
  Type     Reason                 Age                   From                       Message
  ----     ------                 ----                  ----                       -------
  Warning  FailedGetObjectMetric  36m (x13 over 103m)   horizontal-pod-autoscaler  unable to get metric istio_requests_per_min: service on default productpage/unable to fetch metrics from custom metrics API: no custom metrics API (custom.metrics.k8s.io) registered
  Warning  FailedGetObjectMetric  33m (x21 over 11h)    horizontal-pod-autoscaler  unable to get metric istio_requests_per_min: service on default productpage/unable to fetch metrics from custom metrics API: the server is currently unable to handle the request (get services.custom.metrics.k8s.io productpage)
  Warning  FailedGetObjectMetric  13m (x2591 over 11h)  horizontal-pod-autoscaler  unable to get metric istio_requests_per_min: service on default productpage/unable to fetch metrics from custom metrics API: the server could not find the metric istio_requests_per_min for services
  Normal   SuccessfulRescale      4m3s                  horizontal-pod-autoscaler  New size: 1; reason: All metrics below target
  Normal   SuccessfulRescale      74s (x2 over 9m39s)   horizontal-pod-autoscaler  New size: 2; reason: service metric istio_requests_per_min above target
```


You may have noticed that the autoscaler doesn't react immediately to usage spikes. 
By default the metrics sync happens once every 30 seconds and scaling up/down can 
only happen if there was no rescaling within the last 3-5 minutes. 
In this way, the HPA prevents rapid execution of conflicting decisions and gives time for the 
Cluster Autoscaler to kick in.

### Conclusions

Not all systems can meet their SLAs by relying on CPU/memory usage metrics alone, most web and mobile 
backends require autoscaling based on requests per second to handle any traffic bursts. 
For ETL apps, auto scaling could be triggered by the job queue length exceeding some threshold and so on. 
By instrumenting your applications with Prometheus and exposing the right metrics for autoscaling you can 
fine tune your apps to better handle bursts and ensure high availability.
