FROM node:current-alpine

RUN apk add bash && \
    npm install -g @lint-md/cli && \
    npm install -g markdownlint-cli2

ENTRYPOINT [ "/bin/bash" ]
VOLUME [ "/work" ]
WORKDIR /work
