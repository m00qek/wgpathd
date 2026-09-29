# The pinned mkdocs-material image plus mike and what the docs tests need.
ARG MKDOCS_IMAGE
FROM ${MKDOCS_IMAGE}

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && \
    apk add --no-cache git coreutils nodejs

ENTRYPOINT []
