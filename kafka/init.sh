#!/bin/sh
# kafka-init's entrypoint, on every up: the topics, the modules' users <module>_user (SCRAM-SHA-512)
# and their ACLs, from the settings rendered from Vault (secret/env/kafka). Each step is safe to run again: a topic is
# made once and keeps its partitions, a user's password is set again, an ACL is added once.
#   <module>.events  one per module's outbox; only that module's user writes it.
#   audit            every module's user writes it; only audit_user reads it, in group audit.
# Nobody reads <module>.events in MVP 1: the relay writes them for later readers; the calls after a
# commit to other modules go through the relay, not through Kafka readers.
# The passwords go to Kafka in files only this process reads, never on a command line.
# A missing value stops it here, by name.
set -eu
umask 077
bin=/opt/kafka/bin
cat > /tmp/admin.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="${KAFKA_ADMIN_PASSWORD:?KAFKA_ADMIN_PASSWORD is required}";
EOF
kafka() { tool=$1; shift; "$bin/$tool.sh" --bootstrap-server kafka:9092 --command-config /tmp/admin.properties "$@"; }

# topic <name> <partitions> <retention in ms>. Kafka cannot take partitions away: a topic that has a
# different count stops this run, for the operator to decide.
topic() {
  kafka kafka-topics --create --if-not-exists --topic "$1" --partitions "$2" --replication-factor 1 > /dev/null
  have=$(kafka kafka-topics --describe --topic "$1" | sed -n 's/.*PartitionCount: *\([0-9]*\).*/\1/p')
  [ "$have" = "$2" ] || { echo "topic $1 has $have partitions, not $2" >&2; exit 1; }
  kafka kafka-configs --alter --entity-type topics --entity-name "$1" --add-config "retention.ms=$3" > /dev/null
}

# user <name> <password>. The tool's own message on a failure may hold the password: it is not shown.
user() {
  printf 'SCRAM-SHA-512=iterations=8192,password=%s\n' "$2" > /tmp/scram.properties
  kafka kafka-configs --alter --entity-type users --entity-name "$1" --add-config-file /tmp/scram.properties > /dev/null 2>&1 \
    || { echo "user $1: its password was not set" >&2; exit 1; }
  rm /tmp/scram.properties
}

# 7 days for a module's events. audit keeps 14, for the audit module to catch up after a long stop, in one
# partition: the audit chain reads every module's events in one order.
day=86400000
for module in access customer grants antifraud notification catalogue staff; do
  topic "$module.events" 3 $((7 * day))
done
topic audit 1 $((14 * day))

user access_user "${KAFKA_ACCESS_PASSWORD:?KAFKA_ACCESS_PASSWORD is required}"
user customer_user "${KAFKA_CUSTOMER_PASSWORD:?KAFKA_CUSTOMER_PASSWORD is required}"
user grants_user "${KAFKA_GRANTS_PASSWORD:?KAFKA_GRANTS_PASSWORD is required}"
user antifraud_user "${KAFKA_ANTIFRAUD_PASSWORD:?KAFKA_ANTIFRAUD_PASSWORD is required}"
user notification_user "${KAFKA_NOTIFICATION_PASSWORD:?KAFKA_NOTIFICATION_PASSWORD is required}"
user catalogue_user "${KAFKA_CATALOGUE_PASSWORD:?KAFKA_CATALOGUE_PASSWORD is required}"
user staff_user "${KAFKA_STAFF_PASSWORD:?KAFKA_STAFF_PASSWORD is required}"
user audit_user "${KAFKA_AUDIT_PASSWORD:?KAFKA_AUDIT_PASSWORD is required}"

for module in access customer grants antifraud notification catalogue staff; do
  kafka kafka-acls --add --allow-principal "User:${module}_user" --operation Write --topic "$module.events" --topic audit > /dev/null
done
kafka kafka-acls --add --allow-principal User:audit_user --operation Read --topic audit --group audit > /dev/null
echo "kafka: 8 topics, 8 users, their ACLs"
