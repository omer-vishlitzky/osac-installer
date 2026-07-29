#!/usr/bin/env bash
set -euo pipefail

echo "Waiting for AMQ Streams CSV to appear in osac-kafka namespace..."
until oc get csv --no-headers -n osac-kafka 2>/dev/null | grep -q amqstreams; do
  sleep 10
done
AMQ_CSV=$(oc get csv --no-headers -n osac-kafka | awk '/amqstreams/ { print $1 }' | tail -1)

echo "Waiting for CSV ${AMQ_CSV} to succeed..."
until [[ "$(oc get csv "${AMQ_CSV}" -n osac-kafka -o jsonpath='{.status.phase}')" == "Succeeded" ]]; do
  sleep 10
done

echo "Waiting for AMQ Streams cluster operator deployment..."
oc wait --for=condition=Available deploy -l olm.owner="${AMQ_CSV}" -n osac-kafka --timeout=300s

echo "Applying Kafka cluster..."
oc apply -f /config/kafka-cluster.yaml

echo "Waiting for Kafka cluster to be ready..."
until oc wait kafka/osac-kafka -n osac-kafka --for=condition=Ready --timeout=600s 2>/dev/null; do
  echo "Kafka cluster not yet ready, retrying..."
  sleep 15
done

echo "Applying Kafka topics..."
oc apply -f /config/kafka-topics.yaml

echo "Waiting for Kafka topics to be ready..."
for topic in osac.metering.lifecycle osac.metering.heartbeat osac.metering.inference osac.metering.corrections osac.metering.dlq; do
  until oc wait "kafkatopic/${topic}" -n osac-kafka --for=condition=Ready --timeout=120s 2>/dev/null; do
    echo "Topic ${topic} not yet ready, retrying..."
    sleep 5
  done
  echo "Topic ${topic} ready."
done

echo "Applying Kafka user..."
oc apply -f /config/kafka-user.yaml

echo "Waiting for Kafka user to be ready..."
until oc wait kafkauser/osac-metering -n osac-kafka --for=condition=Ready --timeout=120s 2>/dev/null; do
  echo "Kafka user not yet ready, retrying..."
  sleep 5
done

echo "Kafka configuration complete."
