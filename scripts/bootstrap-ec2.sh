#!/bin/bash
# Prepara una EC2 con Amazon Linux 2023 para correr ConsultaYa con Docker Compose.
# Pensado como "User data" al lanzar la instancia (corre como root), pero también
# se puede ejecutar a mano con sudo. Es idempotente.
#
# Instala: docker, plugin compose, plugin buildx, git y el cliente de PostgreSQL (psql).
# Deja docker activo al arrancar y agrega a ec2-user al grupo docker.
# Log: /var/log/consultaya-bootstrap.log
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'AYUDA'
Uso: sudo bash bootstrap-ec2.sh [--help]

Prepara Amazon Linux 2023 (t3.small) para ConsultaYa:
  - dnf: docker, git y cliente de PostgreSQL (postgresql16, o postgresql15 si no existe)
  - plugins de Docker: compose y buildx (binarios oficiales fijados por versión)
  - systemctl enable --now docker; usermod -aG docker ec2-user
  - crea /opt/consultaya con dueño ec2-user
Variables opcionales: COMPOSE_VERSION, BUILDX_VERSION.
Se pega completo en "Advanced details → User data" al lanzar la EC2 (ver docs/06-despliegue-aws.md).
AYUDA
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecútalo como root: sudo bash $0" >&2
  exit 1
fi

exec > >(tee -a /var/log/consultaya-bootstrap.log) 2>&1
echo "== ConsultaYa bootstrap: $(date -u +%FT%TZ)"

COMPOSE_VERSION="${COMPOSE_VERSION:-v2.29.7}"
BUILDX_VERSION="${BUILDX_VERSION:-v0.17.1}"

case "$(uname -m)" in
  x86_64)  ARCH_COMPOSE="x86_64";  ARCH_BUILDX="amd64" ;;
  aarch64) ARCH_COMPOSE="aarch64"; ARCH_BUILDX="arm64" ;;
  *) echo "Arquitectura no soportada: $(uname -m)" >&2; exit 1 ;;
esac

echo "-- Paquetes (dnf)"
dnf install -y docker git
dnf install -y postgresql16 || dnf install -y postgresql15

echo "-- Plugins de Docker"
PLUGINS_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGINS_DIR"
if ! docker compose version >/dev/null 2>&1; then
  curl -fsSL --retry 5 --retry-delay 3 -o "$PLUGINS_DIR/docker-compose" \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH_COMPOSE}"
  chmod +x "$PLUGINS_DIR/docker-compose"
fi
if ! docker buildx version >/dev/null 2>&1; then
  curl -fsSL --retry 5 --retry-delay 3 -o "$PLUGINS_DIR/docker-buildx" \
    "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${ARCH_BUILDX}"
  chmod +x "$PLUGINS_DIR/docker-buildx"
fi

echo "-- Servicio docker"
systemctl enable --now docker
if id ec2-user >/dev/null 2>&1; then
  usermod -aG docker ec2-user
fi

echo "-- Directorio de trabajo"
mkdir -p /opt/consultaya
if id ec2-user >/dev/null 2>&1; then
  chown ec2-user:ec2-user /opt/consultaya
fi

echo "-- Versiones"
docker --version
docker compose version
docker buildx version || true
git --version
psql --version
echo "== Bootstrap terminado: $(date -u +%FT%TZ)"
