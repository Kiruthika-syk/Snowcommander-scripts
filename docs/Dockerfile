# ==============================================================================
# RHEL security tools documentation site
#
# nginx rather than Tomcat: the site is static HTML with no servlets, JSPs or
# Java runtime involved, so Tomcat would add a JVM and a much larger attack
# surface for no benefit. nginx-alpine is a few megabytes.
#
# Build and run from the repository root:
#   podman build -t sectools-docs:latest -f docs/Dockerfile docs/
#   podman run -d --name sectools-docs -p 8080:8080 sectools-docs:latest
#
# Then browse http://<host>:8080/
# ==============================================================================

# Fully qualified: podman enforces short-name resolution and cannot prompt for
# a registry in a non-interactive build, so "nginx:1.27-alpine" fails there.
FROM docker.io/library/nginx:1.27-alpine

LABEL org.opencontainers.image.title="sectools-docs" \
      org.opencontainers.image.description="Static documentation for the RHEL security tools security tooling"

# Unprivileged: listens on 8080, so no NET_BIND_SERVICE capability is needed.
COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html guide.pdf /usr/share/nginx/html/

# nginx:alpine ships an unprivileged 'nginx' user (uid 101). Give it ownership
# of the paths it needs so the container can run as that user.
RUN mkdir -p /tmp/client_temp \
    && chown -R nginx:nginx /usr/share/nginx/html /tmp \
    && chmod 0644 /usr/share/nginx/html/index.html \
                   /usr/share/nginx/html/guide.pdf

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1

CMD ["nginx", "-g", "daemon off;"]
