#!/usr/bin/env bash
# Deploy do frontend (bia/client, React/Vite) em um bucket S3.
#
#  1. Build:  npm install + npm run build, embutindo a URL da API (VITE_API_URL) no bundle.
#  2. Deploy: aws s3 sync da pasta build/ para o bucket (com --delete).
#
# O backend e implantado separadamente (ver deploy_be_ecs.sh).
#
# Uso: ./deploy_fe_s3.sh [--profile <perfil-aws>] [--bucket <nome>] [--api-url <url>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/bia/client"
BUILD_DIR="$CLIENT_DIR/build"
BUCKET="innovsysti-dev-desafio3"
API_URL="http://54.172.170.161"
PROFILE=""

function usage {
    echo "Uso: $0 [--profile <perfil-aws>] [--bucket <nome>] [--api-url <url>]"
    echo "  --profile  Perfil AWS a utilizar (opcional). Sem ele, usa as credenciais padrao."
    echo "  --bucket   Bucket S3 de destino (padrao: $BUCKET)"
    echo "  --api-url  URL da API embutida no build via VITE_API_URL (padrao: $API_URL)"
}

function parse_args {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile|--bucket|--api-url)
                [ $# -ge 2 ] || { echo "  $1 requer um valor."; usage; exit 1; }
                case "$1" in
                    --profile) PROFILE="$2" ;;
                    --bucket) BUCKET="$2" ;;
                    --api-url) API_URL="$2" ;;
                esac
                shift 2 ;;
            --profile=*) PROFILE="${1#*=}"; shift ;;
            --bucket=*) BUCKET="${1#*=}"; shift ;;
            --api-url=*) API_URL="${1#*=}"; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "  Parametro desconhecido: $1"; usage; exit 1 ;;
        esac
    done
    AWS_ARGS=()
    if [ -n "$PROFILE" ]; then
        AWS_ARGS=(--profile "$PROFILE")
    fi
}

function check_requirements {
    command -v aws >/dev/null || { echo "  aws cli nao encontrado."; exit 1; }
    command -v npm >/dev/null || { echo "  npm nao encontrado."; exit 1; }
    [ -d "$CLIENT_DIR" ] || { echo "  $CLIENT_DIR nao encontrado."; exit 1; }
}

function build_react {
    echo "  Iniciando build (VITE_API_URL=$API_URL) ..."
    (
        cd "$CLIENT_DIR"
        npm install --legacy-peer-deps --loglevel=error
        VITE_API_URL="$API_URL" npm run build
    )
    echo "  Build finalizado."
}

function deploy_s3 {
    if [ ! -d "$BUILD_DIR" ]; then
        echo "  Pasta $BUILD_DIR nao encontrada. O build falhou?"
        exit 1
    fi

    echo "  Copiando build para s3://$BUCKET ..."
    aws s3 sync "$BUILD_DIR" "s3://$BUCKET" --delete "${AWS_ARGS[@]}"
    echo "  Deploy finalizado: s3://$BUCKET"
}

parse_args "$@"
check_requirements
build_react
deploy_s3
