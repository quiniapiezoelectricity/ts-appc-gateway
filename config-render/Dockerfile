FROM alpine:3.19@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1
RUN apk add --no-cache gettext
COPY render.sh /render.sh
RUN chmod +x /render.sh
# Templates are bind-mounted from ./templates/ at runtime.
# See docker-compose.yml. No rebuild needed to iterate on templates.
CMD ["/render.sh"]
