FROM alpine:3.19
RUN apk add --no-cache gettext
COPY render.sh /render.sh
RUN chmod +x /render.sh
# Templates are bind-mounted from ./templates/ at runtime.
# See docker-compose.yml. No rebuild needed to iterate on templates.
CMD ["/render.sh"]
