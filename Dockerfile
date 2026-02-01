FROM openresty/openresty:1.25.3.2-alpine

# Install lua-resty-http for API communication
RUN opm get ledgetech/lua-resty-http

# Create directory structure
RUN mkdir -p /opt/slave/conf \
             /opt/slave/lua/lib \
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
ENV CONFIG_PULL_INTERVAL=30
ENV TELEMETRY_FLUSH_INTERVAL=60
ENV QUOTA_SYNC_INTERVAL=300
ENV HEARTBEAT_INTERVAL=60

# Expose ports
EXPOSE 80 443

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Start OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
