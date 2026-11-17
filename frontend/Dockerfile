# Front-end : build Vite dans une image Node, puis service des fichiers statiques
# par Nginx non privilégié (UID 101, port 8080). Image finale ≈ 25 Mo, sans Node ni sources.

FROM node:26-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.29-alpine AS runtime
LABEL org.opencontainers.image.title="resaflow-frontend"
# L'upstream de l'API est injecté au démarrage par envsubst (templates officiels de l'image Nginx).
ENV BACKEND_UPSTREAM=http://api:8000
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /src/dist /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s CMD ["wget", "-qO-", "http://127.0.0.1:8080/healthz"]
USER 101
