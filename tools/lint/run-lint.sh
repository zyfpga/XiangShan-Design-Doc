#!/bin/bash

# Should have lint-md (specialized for Chinese doc) and markdownlint-cli2 installed
# Hint: use `npm install -g lint-md markdownlint-cli2` to install them
# Hint: or use docker:
#   Build docker image:
#   docker build -t xiangshan-design-doc-linter -f tools/lint/Dockerfile .
#   Run lint in container:
#   docker run -v $(pwd):/work xiangshan-design-doc-linter tools/lint/run-lint.sh

AUTOFIX=${AUTOFIX:-true}
TARGET=${TARGET:-"./**/*.md"}
GENERAL_FLAGS=""

if [[ "${AUTOFIX}" == "true" ]]; then
    GENERAL_FLAGS+=" --fix"
fi

markdownlint-cli2 ${GENERAL_FLAGS} ${TARGET}
lint-md ${GENERAL_FLAGS} ${TARGET}
