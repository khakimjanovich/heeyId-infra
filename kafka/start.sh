#!/bin/sh
# kafka's entrypoint: one Kafka node in KRaft mode (broker and controller in one process), ACLs on, no
# topic made by a client (kafka/init.sh makes them). Two listeners, both SASL:
#   CLIENT      :9092 on the network: user admin (PLAIN) for this node itself, kafka-init and the health
#               check; the modules' users (SCRAM-SHA-512, made by kafka-init).
#   CONTROLLER  127.0.0.1:9093, inside this container only: user admin (PLAIN).
# Admin signs in with PLAIN from this file, not SCRAM: its password then changes with Vault on the next
# start, where a SCRAM user would need its old password to change it.
# The password goes to Kafka in a properties file only this process reads, never on its command line.
# A missing value stops it here, by name.
# ponytail: one node, replication 1; a three-node cluster with replication 3 when one host is not enough.
set -eu
umask 077
admin="${KAFKA_ADMIN_PASSWORD:?KAFKA_ADMIN_PASSWORD is required}"
plain="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"$admin\" user_admin=\"$admin\";"
cat > /tmp/server.properties << EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@127.0.0.1:9093
listeners=CLIENT://:9092,CONTROLLER://127.0.0.1:9093
advertised.listeners=CLIENT://kafka:9092
listener.security.protocol.map=CLIENT:SASL_PLAINTEXT,CONTROLLER:SASL_PLAINTEXT
inter.broker.listener.name=CLIENT
controller.listener.names=CONTROLLER
sasl.mechanism.inter.broker.protocol=PLAIN
sasl.mechanism.controller.protocol=PLAIN
listener.name.client.sasl.enabled.mechanisms=PLAIN,SCRAM-SHA-512
listener.name.client.plain.sasl.jaas.config=$plain
listener.name.client.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;
listener.name.controller.sasl.enabled.mechanisms=PLAIN
listener.name.controller.plain.sasl.jaas.config=$plain
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
super.users=User:admin
allow.everyone.if.no.acl.found=false
auto.create.topics.enable=false
log.dirs=/var/lib/kafka/data
default.replication.factor=1
min.insync.replicas=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1
EOF
# The health check's sign-in (docker-compose.yml).
cat > /tmp/admin.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="$admin";
EOF
# The first start formats the volume with a new cluster id; a later start finds it formatted.
[ -f /var/lib/kafka/data/meta.properties ] \
  || /opt/kafka/bin/kafka-storage.sh format -t "$(/opt/kafka/bin/kafka-storage.sh random-uuid)" -c /tmp/server.properties
export KAFKA_HEAP_OPTS="-Xms512m -Xmx512m"
exec /opt/kafka/bin/kafka-server-start.sh /tmp/server.properties
