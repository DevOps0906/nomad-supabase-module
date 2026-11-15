# nginx 비루트(uid 101, 8080). 이미지 태그 확인일: 2026-11-13 (1.31.7-alpine이 최신 stable 계열)
FROM nginxinc/nginx-unprivileged:1.31.7-alpine@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 . /usr/share/nginx/html/
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
