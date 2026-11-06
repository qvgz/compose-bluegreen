# v1 存在 /health，返回 200；其他版本没有该文件，返回 404
FROM busybox:musl
ARG VERSION=v1
RUN mkdir -p /www && if [ "$VERSION" = v1 ]; then echo ok >/www/health; fi
EXPOSE 8080
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD ["wget", "-qO", "/dev/null", "http://127.0.0.1:8080/health"]
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
