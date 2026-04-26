# =============================================================================
# nginx.conf — generated for ${NODE_NAME} (Milvus ${MILVUS_VERSION})
#
# Layer-4 (TCP) load balancer in front of all ${CLUSTER_SIZE} Milvus
# instances. Clients connect to any node's :${NGINX_LB_PORT}; nginx
# round-robins requests across healthy backends.
#
# Health-checking is passive (open-source nginx limitation): a backend
# is marked down after `max_fails` failed connection attempts within
# `fail_timeout`, then re-tried. For active health checks, use nginx-plus
# or replace with HAProxy.
#
# DO NOT EDIT BY HAND. Re-render with `milvus-onprem render`.
# =============================================================================

worker_processes auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
  worker_connections  1024;
}

stream {
  log_format proxy '$remote_addr [$time_local] '
                   '$protocol $status $bytes_sent $bytes_received '
                   '$session_time "$upstream_addr" '
                   '"$upstream_bytes_sent" "$upstream_bytes_received" '
                   '"$upstream_connect_time"';

  access_log /var/log/nginx/access.log proxy;

  upstream milvus_backends {
${NGINX_UPSTREAM_BLOCK}  }

  server {
    listen ${NGINX_LB_PORT};
    proxy_pass         milvus_backends;
    proxy_timeout      600s;
    proxy_connect_timeout 5s;
    proxy_socket_keepalive on;
  }
}
