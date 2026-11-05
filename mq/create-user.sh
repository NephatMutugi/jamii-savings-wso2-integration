#!/usr/bin/env bash
# Creates the broker user MI authenticates with, from .env.
#
# Why this is a script and not part of mq/definitions.json: RabbitMQ skips
# creating RABBITMQ_DEFAULT_USER when a definitions file is loaded on a blank
# node, and a definitions file that declared the user would have to carry its
# password hash in version control. Topology stays committed; the credential
# stays in .env.
#
# Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

docker compose exec -T rabbitmq rabbitmqctl add_user "$JAMII_MQ_USER" "$JAMII_MQ_PASSWORD" 2>/dev/null \
  || docker compose exec -T rabbitmq rabbitmqctl change_password "$JAMII_MQ_USER" "$JAMII_MQ_PASSWORD"
docker compose exec -T rabbitmq rabbitmqctl set_permissions -p / "$JAMII_MQ_USER" ".*" ".*" ".*"
docker compose exec -T rabbitmq rabbitmqctl set_user_tags "$JAMII_MQ_USER" management
echo "broker user '$JAMII_MQ_USER' ready"
