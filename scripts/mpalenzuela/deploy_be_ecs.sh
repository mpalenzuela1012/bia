#!/usr/bin/env bash
# Deploy ou rollback do backend (pasta bia/) no ECS, usando imagens do ECR.
#
#  1-Deploy:   build + push da imagem (tag = short commit hash), registra nova revisao da
#              task definition com a imagem e atualiza o service ECS.
#  2-Rollback: lista as 5 ultimas imagens do ECR, permite escolher uma, registra nova revisao
#              da task definition com a imagem escolhida e atualiza o service ECS.
#
# O frontend NAO entra na imagem (ver bia/Dockerfile.backend e bia/Dockerfile.backend.dockerignore).
#
# Uso: ./deploy_be_s3.sh [--profile <perfil-aws>] [--cluster <nome>] [--service <nome>] [--task-family <nome>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/bia"
REPO="bia"
DOCKERFILE="Dockerfile.backend"
CONTAINER_NAME="bia"
TASK_FAMILY="task-bia"
CLUSTER="cluster-bia"
SERVICE="service-bia"
PROFILE=""

function usage {
    echo "Uso: $0 [--profile <perfil-aws>] [--cluster <nome>] [--service <nome>] [--task-family <nome>]"
    echo "  --profile      Perfil AWS a utilizar (opcional). Sem ele, usa as credenciais padrao."
    echo "  --cluster      Cluster ECS (padrao: $CLUSTER)"
    echo "  --service      Service ECS (padrao: $SERVICE)"
    echo "  --task-family  Task definition (padrao: $TASK_FAMILY)"
}

function parse_args {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile|--cluster|--service|--task-family)
                [ $# -ge 2 ] || { echo "  $1 requer um valor."; usage; exit 1; }
                case "$1" in
                    --profile) PROFILE="$2" ;;
                    --cluster) CLUSTER="$2" ;;
                    --service) SERVICE="$2" ;;
                    --task-family) TASK_FAMILY="$2" ;;
                esac
                shift 2 ;;
            --profile=*) PROFILE="${1#*=}"; shift ;;
            --cluster=*) CLUSTER="${1#*=}"; shift ;;
            --service=*) SERVICE="${1#*=}"; shift ;;
            --task-family=*) TASK_FAMILY="${1#*=}"; shift ;;
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
    command -v jq >/dev/null || { echo "  jq nao encontrado."; exit 1; }
    if [ "$MODE" = "1" ]; then
        command -v docker >/dev/null || { echo "  docker nao encontrado."; exit 1; }
        [ -f "$APP_DIR/$DOCKERFILE" ] || { echo "  $APP_DIR/$DOCKERFILE nao encontrado."; exit 1; }
    fi
}

function choose_mode {
    echo "O que deseja fazer?"
    echo "  1 - Deploy"
    echo "  2 - Rollback"
    read -r -p "Opcao: " MODE
    case "$MODE" in
        1|2) ;;
        *) echo "  Opcao invalida: $MODE"; exit 1 ;;
    esac
}

function prepare_aws_vars {
    REGION="${AWS_REGION:-$(aws configure get region "${AWS_ARGS[@]}" 2>/dev/null || true)}"
    REGION="${REGION:-us-east-1}"

    ACCOUNT_ID="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --region "$REGION" --query Account --output text)"
    REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
    echo "  Conta: $ACCOUNT_ID | Regiao: $REGION"
}

function prepare_tag {
    # Alteracoes fora de client/ mudariam a imagem sem mudar o hash da tag
    if [ -n "$(git -C "$APP_DIR" status --porcelain -- . ':!client')" ]; then
        echo "  Ha alteracoes nao commitadas em bia/ (fora de client/). Faca commit para que a tag reflita a imagem."
        exit 1
    fi
    TAG="$(git -C "$APP_DIR" rev-parse --short HEAD)"
    IMAGE_URI="$REGISTRY/$REPO:$TAG"
    echo "  Imagem: $IMAGE_URI"
}

function login_ecr {
    echo "  Fazendo login no ECR..."
    aws ecr get-login-password --region "$REGION" "${AWS_ARGS[@]}" \
        | docker login --username AWS --password-stdin "$REGISTRY"
}

function build_image {
    echo "  Gerando imagem do backend..."
    docker build -f "$APP_DIR/$DOCKERFILE" -t "$REPO:$TAG" -t "$IMAGE_URI" "$APP_DIR"
}

function push_image {
    echo "  Enviando imagem para o ECR..."
    docker push "$IMAGE_URI"
    echo "  Imagem enviada: $IMAGE_URI"
}

# Registra nova revisao da task definition trocando a imagem do container e atualiza o service.
function update_task_and_service {
    local image="$1"

    echo "  Lendo task definition $TASK_FAMILY ..."
    local current
    current="$(aws ecs describe-task-definition "${AWS_ARGS[@]}" --region "$REGION" \
        --task-definition "$TASK_FAMILY" --query taskDefinition --output json)"

    # Container alvo: o chamado "bia"; se nao existir e houver so um container, usa esse
    local target
    target="$(jq -r --arg n "$CONTAINER_NAME" '
        if any(.containerDefinitions[]; .name == $n) then $n
        elif (.containerDefinitions | length) == 1 then .containerDefinitions[0].name
        else empty end' <<<"$current")"
    if [ -z "$target" ]; then
        echo "  Container '$CONTAINER_NAME' nao encontrado na task definition $TASK_FAMILY."
        return 1
    fi

    local new_def
    new_def="$(jq --arg n "$target" --arg img "$image" '
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
            .registeredAt, .registeredBy)
        | .containerDefinitions |= map(if .name == $n then .image = $img else . end)' <<<"$current")"

    echo "  Registrando nova revisao com a imagem $image ..."
    local new_arn
    new_arn="$(aws ecs register-task-definition "${AWS_ARGS[@]}" --region "$REGION" \
        --cli-input-json "$new_def" --query taskDefinition.taskDefinitionArn --output text)"
    echo "  Nova revisao: $new_arn"

    echo "  Atualizando service $SERVICE no cluster $CLUSTER ..."
    aws ecs update-service "${AWS_ARGS[@]}" --region "$REGION" \
        --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$new_arn" \
        --query 'service.[serviceName,taskDefinition]' --output text
    echo "  Rolling update iniciado."
}

function do_deploy {
    prepare_tag
    login_ecr
    build_image
    push_image
    update_task_and_service "$IMAGE_URI"
    echo "  Deploy finalizado: $IMAGE_URI"
}

function do_rollback {
    echo "  Ultimas 5 imagens no ECR ($REPO):"
    local lines
    mapfile -t lines < <(aws ecr describe-images "${AWS_ARGS[@]}" --region "$REGION" \
        --repository-name "$REPO" --output text \
        --query "reverse(sort_by(imageDetails[?imageTags!=null && length(imageTags[?@!='latest'])>\`0\`], &imagePushedAt))[:5].[imageTags[?@!='latest']|[0], imagePushedAt]")

    if [ "${#lines[@]}" -eq 0 ]; then
        echo "  Nenhuma imagem com tag encontrada no repositorio $REPO."
        exit 1
    fi

    local tags=() i=1 tag pushed
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r tag pushed <<<"$line"
        tags+=("$tag")
        echo "    $i - $tag  (enviada em $pushed)"
        i=$((i + 1))
    done

    local choice
    read -r -p "Selecione a imagem (1-${#tags[@]}): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        echo "  Selecao invalida: $choice"
        exit 1
    fi

    local selected="${tags[$((choice - 1))]}"
    IMAGE_URI="$REGISTRY/$REPO:$selected"
    update_task_and_service "$IMAGE_URI"
    echo "  Rollback finalizado: $IMAGE_URI"
}

parse_args "$@"
choose_mode
check_requirements
prepare_aws_vars
if [ "$MODE" = "1" ]; then
    do_deploy
else
    do_rollback
fi
