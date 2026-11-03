FROM node:26-alpine

ARG APP_VERSION=dev
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION}
WORKDIR /app

COPY package.json package-lock.json ./
# npm is only needed to install; removing it drops its bundled dependencies from the runtime image.
RUN npm ci --omit=dev \
    && npm cache clean --force \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

COPY src ./src

USER 1000
EXPOSE 3000
CMD ["node", "src/server.js"]
