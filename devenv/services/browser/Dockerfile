# Playwright with Alpine's Chromium, as in luci-sso (devenv/services/browser there).
ARG NODE_VERSION=25
ARG ALPINE_VERSION=3.23
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION}

RUN apk add --no-cache chromium nss freetype harfbuzz ttf-freefont font-dejavu

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --quiet
