FROM alpine:latest
RUN apk add --no-cache docker-cli docker-cli-compose tzdata
ENV TZ=Asia/Shanghai
COPY --chmod=755 compose-bluegreen.sh /usr/local/bin/compose-bluegreen
ENTRYPOINT ["compose-bluegreen"]
