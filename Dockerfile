FROM openresty/openresty:1.25.3.2-alpine

# Install lua-resty-http for API communication
RUN apk add --no-cache curl unzip && \
    mkdir -p /usr/local/openresty/site/lualib/resty && \
    cd /tmp && \
    curl -fSL https://github.com/ledgetech/lua-resty-http/archive/refs/tags/v0.17.2.tar.gz -o lua-resty-http.tar.gz && \
    tar xzf lua-resty-http.tar.gz && \
    cp lua-resty-http-0.17.2/lib/resty/http.lua /usr/local/openresty/site/lualib/resty/ && \
    cp lua-resty-http-0.17.2/lib/resty/http_headers.lua /usr/local/openresty/site/lualib/resty/ && \
    cp lua-resty-http-0.17.2/lib/resty/http_connect.lua /usr/local/openresty/site/lualib/resty/ 2>/dev/null || true && \
    rm -rf /tmp/lua-resty-http*

# Create directory structure
RUN mkdir -p /opt/slave/conf \
             /opt/slave/lua/lib \
             /opt/slave/lua/filters \
             /opt/slave/lua/modules \
             /opt/slave/templates \
             /var/log/openresty

# Copy configuration files
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY conf/upstream.conf /opt/slave/conf/upstream.conf
COPY conf/maps.conf /opt/slave/conf/maps.conf
COPY conf/server.conf /opt/slave/conf/server.conf

# Copy Lua files
COPY lua/ /opt/slave/lua/

# Environment variables (set defaults)
ENV UHDADMIN_URL=http://localhost:8000
ENV APP_TOKEN=""
ENV REDIS_HOST=127.0.0.1
ENV REDIS_PORT=6379
ENV REDIS_DB=0
ENV REDIS_PASSWORD=""
ENV CONFIG_PULL_INTERVAL=30
ENV TELEMETRY_FLUSH_INTERVAL=60
ENV QUOTA_SYNC_INTERVAL=300
ENV HEARTBEAT_INTERVAL=60
ENV EMBY_API_KEY=""
ENV EMBY_SERVER_URL=""
ENV TOKEN_RESOLVE_INTERVAL=30
ENV SESSION_HEARTBEAT_INTERVAL=30

# Expose ports
EXPOSE 80 443

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Start OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
