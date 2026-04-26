  # --- Pulsar singleton: Milvus 2.5 message queue (only on PULSAR_HOST) -----
  # SPOF caveat: this is a single Pulsar broker on one node, NOT a Pulsar
  # cluster. If this node dies, writes stop until Pulsar comes back.
  # For real HA, run a separate 3-broker Pulsar cluster and point Milvus
  # at it via PULSAR_HOST=external:6650 (and remove this service).
  pulsar:
    image: apachepulsar/pulsar:${PULSAR_IMAGE_TAG}
    container_name: milvus-pulsar
    network_mode: host
    restart: always
    command: ["sh", "-c", "bin/pulsar standalone --no-functions-worker --no-stream-storage"]
    volumes:
      - ${DATA_ROOT}/pulsar:/pulsar/data
    environment:
      - PULSAR_PREFIX_brokerServicePort=${PULSAR_BROKER_PORT}
      - PULSAR_PREFIX_webServicePort=${PULSAR_HTTP_PORT}
    healthcheck:
      test: ["CMD", "bin/pulsar-admin", "brokers", "healthcheck"]
      interval: 30s
      timeout: 30s
      retries: 5
      start_period: 90s
