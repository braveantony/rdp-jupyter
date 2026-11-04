# RDP test client: FreeRDP on a virtual X display, driven with xdotool
# (ported from rdp-vscode's test/e2e/client)
FROM alpine:3.22
RUN apk add --no-cache freerdp xvfb xwd imagemagick xdotool bash font-dejavu
COPY login.sh /login.sh
ENTRYPOINT ["/login.sh"]
