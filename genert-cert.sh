#!/bin/bash

# 生成根秘钥及证书
mkdir cert-dir
openssl req -x509 -sha256 -newkey rsa:1024 -keyout cert-dir/ca.key -out cert-dir/ca.crt -days 35600 -nodes -subj '/CN=custom-metrics-apiserver LStack Authority'

# 生成服务器密钥，证书并使用CA证书签名
openssl genrsa -out cert-dir/server.key 1024
openssl req -new -key cert-dir/server.key -subj "/CN=custom-metrics-apiserver" -out cert-dir/server.csr
openssl x509 -req -in cert-dir/server.csr -CA cert-dir/ca.crt -CAkey cert-dir/ca.key -CAcreateserial -out cert-dir/server.crt -days 36500

kubectl create secret generic cm-adapter-serving-certs \
  --from-file=serving.crt=cert-dir/server.crt \
  --from-file=serving.key=cert-dir/server.key \
  --from-file=ca.crt=cert-dir/ca.crt \
  -n lstack-system
