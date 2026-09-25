#!/usr/bin/env bash
# =============================================================================
# ecs-manager.sh — Gerenciador de deploy/rollback/listagem para ECS
# Projeto: BIA | Formação AWS
#
# Uso: ./scripts/ecs-manager.sh
# Deve ser executado a partir da raiz do repositório.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Cores e helpers de output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${RESET} $*"; }
error()   { echo -e "${RED}[ERRO]${RESET}  $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n"; }

# -----------------------------------------------------------------------------
# Pré-requisitos
# -----------------------------------------------------------------------------
check_dependencies() {
  local missing=()
  for cmd in aws docker git jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Dependências ausentes: ${missing[*]}"
    error "Instale-as antes de continuar."
    exit 1
  fi
}

# Verifica que está na raiz do repositório git
check_git_repo() {
  if ! git rev-parse --git-dir &>/dev/null; then
    error "Este script deve ser executado a partir da raiz do repositório git."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Leitura de parâmetros iniciais (com valores padrão)
# -----------------------------------------------------------------------------
read_parameters() {
  header "Configuração Inicial"

  read -rp "Região AWS           [us-east-1]: " AWS_REGION
  AWS_REGION="${AWS_REGION:-us-east-1}"

  read -rp "Cluster ECS          [cluster-bia-alb]: " ECS_CLUSTER
  ECS_CLUSTER="${ECS_CLUSTER:-cluster-bia-alb}"

  read -rp "Service ECS          [service-bia-alb]: " ECS_SERVICE
  ECS_SERVICE="${ECS_SERVICE:-service-bia-alb}"

  read -rp "Repositório ECR      [bia]: " ECR_REPO
  ECR_REPO="${ECR_REPO:-bia}"

  echo ""
  info "Região:     ${AWS_REGION}"
  info "Cluster:    ${ECS_CLUSTER}"
  info "Service:    ${ECS_SERVICE}"
  info "ECR Repo:   ${ECR_REPO}"
  echo ""
}

# -----------------------------------------------------------------------------
# Obtém o ECR registry (account_id.dkr.ecr.region.amazonaws.com)
# -----------------------------------------------------------------------------
get_ecr_registry() {
  local account_id
  account_id=$(aws sts get-caller-identity \
    --region "$AWS_REGION" \
    --query "Account" \
    --output text)

  echo "${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
}

# -----------------------------------------------------------------------------
# Obtém a task definition family associada ao service
# -----------------------------------------------------------------------------
get_task_definition_family() {
  local task_def_arn
  task_def_arn=$(aws ecs describe-services \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --query "services[0].taskDefinition" \
    --output text)

  if [[ "$task_def_arn" == "None" || -z "$task_def_arn" ]]; then
    error "Service '${ECS_SERVICE}' não encontrado no cluster '${ECS_CLUSTER}'."
    exit 1
  fi

  # Extrai apenas o family name (sem a revisão)
  echo "$task_def_arn" | awk -F'/' '{print $NF}' | awk -F':' '{print $1}'
}

# -----------------------------------------------------------------------------
# Autentica Docker no ECR
# -----------------------------------------------------------------------------
ecr_login() {
  local registry="$1"
  info "Autenticando Docker no ECR..."
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$registry" \
    > /dev/null
  success "Login no ECR realizado."
}

# -----------------------------------------------------------------------------
# Lista as últimas 10 revisões da task definition com suas imagens
# Retorna: array associativo revisao -> tag_da_imagem
# -----------------------------------------------------------------------------
list_task_def_revisions() {
  local family="$1"

  # Busca as revisões ativas em ordem decrescente, limita a 10
  local revisions
  revisions=$(aws ecs list-task-definitions \
    --region "$AWS_REGION" \
    --family-prefix "$family" \
    --status ACTIVE \
    --sort DESC \
    --max-items 10 \
    --query "taskDefinitionArns" \
    --output json)

  echo "$revisions"
}

# Extrai a tag da imagem de uma task definition ARN
get_image_tag_from_task_def() {
  local task_def_arn="$1"

  local image
  image=$(aws ecs describe-task-definition \
    --region "$AWS_REGION" \
    --task-definition "$task_def_arn" \
    --query "taskDefinition.containerDefinitions[0].image" \
    --output text)

  # Extrai apenas a tag (parte após ":")
  echo "$image" | awk -F':' '{print $NF}'
}

# Obtém a revisão atual em uso pelo service
get_current_revision() {
  local task_def_arn
  task_def_arn=$(aws ecs describe-services \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --query "services[0].taskDefinition" \
    --output text)

  echo "$task_def_arn" | awk -F':' '{print $NF}'
}

# -----------------------------------------------------------------------------
# AÇÃO: LIST — Exibe as últimas 10 versões disponíveis
# -----------------------------------------------------------------------------
action_list() {
  header "Versões Disponíveis"

  local family
  family=$(get_task_definition_family)
  info "Task Definition Family: ${family}"

  local current_rev
  current_rev=$(get_current_revision)
  info "Revisão atual em uso:   ${current_rev}"
  echo ""

  local revisions
  revisions=$(list_task_def_revisions "$family")

  local count
  count=$(echo "$revisions" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    warn "Nenhuma revisão ativa encontrada para a family '${family}'."
    return
  fi

  printf "  %-5s %-12s %-45s %s\n" "REV" "TAG" "TASK DEF ARN" "STATUS"
  printf "  %-5s %-12s %-45s %s\n" "---" "-----------" "--------------------------------------------" "--------"

  for i in $(seq 0 $((count - 1))); do
    local arn
    arn=$(echo "$revisions" | jq -r ".[$i]")

    local rev_num
    rev_num=$(echo "$arn" | awk -F':' '{print $NF}')

    local tag
    tag=$(get_image_tag_from_task_def "$arn")

    local status=""
    if [[ "$rev_num" == "$current_rev" ]]; then
      status="${GREEN}← EM USO${RESET}"
    fi

    printf "  %-5s %-12s %-45s " "$rev_num" "$tag" "$arn"
    echo -e "$status"
  done

  echo ""
}

# -----------------------------------------------------------------------------
# AÇÃO: DEPLOY — Build, push e deploy com a tag do commit atual
# -----------------------------------------------------------------------------
action_deploy() {
  header "Deploy"

  # Obtém short commit hash
  local commit_hash
  commit_hash=$(git rev-parse --short HEAD)
  info "Commit hash: ${commit_hash}"

  local registry
  registry=$(get_ecr_registry)
  local full_image="${registry}/${ECR_REPO}"

  info "Imagem alvo: ${full_image}:${commit_hash}"

  # Confirma antes de prosseguir
  echo ""
  read -rp "$(echo -e "${YELLOW}Confirma o deploy para o service '${ECS_SERVICE}' no cluster '${ECS_CLUSTER}'? [s/N]: ${RESET}")" confirm
  if [[ ! "$confirm" =~ ^[sS]$ ]]; then
    warn "Deploy cancelado pelo usuário."
    return
  fi
  echo ""

  # Login no ECR
  ecr_login "$registry"

  # Build da imagem
  info "Iniciando build da imagem Docker..."
  docker build -t "${full_image}:${commit_hash}" -t "${full_image}:latest" .
  success "Build concluído: ${full_image}:${commit_hash}"

  # Push da imagem
  info "Fazendo push para o ECR..."
  docker push "${full_image}:${commit_hash}"
  docker push "${full_image}:latest"
  success "Push concluído."

  # Obtém a task definition atual para clonar suas configurações
  local family
  family=$(get_task_definition_family)

  info "Registrando nova task definition com a imagem ${commit_hash}..."

  # Obtém o JSON da task def atual e substitui apenas a imagem
  local new_task_def_json
  new_task_def_json=$(aws ecs describe-task-definition \
    --region "$AWS_REGION" \
    --task-definition "$family" \
    --query "taskDefinition" \
    --output json \
    | jq \
        --arg IMAGE "${full_image}:${commit_hash}" \
        'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
         | .containerDefinitions[0].image = $IMAGE')

  # Registra a nova revisão
  local new_task_def_arn
  new_task_def_arn=$(aws ecs register-task-definition \
    --region "$AWS_REGION" \
    --cli-input-json "$new_task_def_json" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text)

  success "Nova task definition registrada: ${new_task_def_arn}"

  # Atualiza o service
  info "Atualizando o service ECS..."
  aws ecs update-service \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --task-definition "$new_task_def_arn" \
    --query "service.serviceArn" \
    --output text > /dev/null

  success "Service atualizado. Aguardando estabilização..."
  echo ""

  # Aguarda o deploy estabilizar (timeout ~10 min)
  aws ecs wait services-stable \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE"

  success "Deploy concluído com sucesso! Versão em produção: ${commit_hash}"
}

# -----------------------------------------------------------------------------
# AÇÃO: ROLLBACK — Escolhe uma revisão anterior e faz o rollback
# -----------------------------------------------------------------------------
action_rollback() {
  header "Rollback"

  local family
  family=$(get_task_definition_family)

  local current_rev
  current_rev=$(get_current_revision)

  info "Task Definition Family: ${family}"
  info "Revisão atual em uso:   ${current_rev}"
  echo ""

  # Carrega as revisões disponíveis
  local revisions
  revisions=$(list_task_def_revisions "$family")

  local count
  count=$(echo "$revisions" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    warn "Nenhuma revisão ativa encontrada. Rollback não é possível."
    return
  fi

  # Exibe menu numerado de versões
  echo -e "${BOLD}Versões disponíveis para rollback:${RESET}"
  echo ""
  printf "  %-4s %-12s %-45s %s\n" "Nº" "TAG" "TASK DEF ARN" "STATUS"
  printf "  %-4s %-12s %-45s %s\n" "--" "-----------" "--------------------------------------------" "--------"

  declare -A rev_map  # número no menu -> ARN completo

  local menu_num=1
  for i in $(seq 0 $((count - 1))); do
    local arn
    arn=$(echo "$revisions" | jq -r ".[$i]")

    local rev_num
    rev_num=$(echo "$arn" | awk -F':' '{print $NF}')

    local tag
    tag=$(get_image_tag_from_task_def "$arn")

    local status=""
    if [[ "$rev_num" == "$current_rev" ]]; then
      status="${GREEN}← EM USO${RESET}"
    fi

    rev_map["$menu_num"]="$arn"

    printf "  %-4s %-12s %-45s " "$menu_num" "$tag" "$arn"
    echo -e "$status"

    ((menu_num++))
  done

  echo ""

  # Solicita a escolha
  local choice
  while true; do
    read -rp "$(echo -e "${YELLOW}Digite o número da versão para rollback (1-${count}): ${RESET}")" choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
      break
    else
      warn "Opção inválida. Por favor, escolha um número entre 1 e ${count}."
    fi
  done

  local chosen_arn="${rev_map[$choice]}"
  local chosen_rev
  chosen_rev=$(echo "$chosen_arn" | awk -F':' '{print $NF}')
  local chosen_tag
  chosen_tag=$(get_image_tag_from_task_def "$chosen_arn")

  # Confirma rollback
  echo ""
  warn "Você selecionou: revisão ${chosen_rev} | imagem tag: ${chosen_tag}"
  read -rp "$(echo -e "${YELLOW}Confirma o rollback para o service '${ECS_SERVICE}' no cluster '${ECS_CLUSTER}'? [s/N]: ${RESET}")" confirm
  if [[ ! "$confirm" =~ ^[sS]$ ]]; then
    warn "Rollback cancelado pelo usuário."
    return
  fi
  echo ""

  # Atualiza o service para a revisão escolhida
  info "Aplicando rollback para a revisão ${chosen_rev}..."
  aws ecs update-service \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --task-definition "$chosen_arn" \
    --query "service.serviceArn" \
    --output text > /dev/null

  success "Service atualizado. Aguardando estabilização..."
  echo ""

  aws ecs wait services-stable \
    --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE"

  success "Rollback concluído! Service rodando com a imagem tag: ${chosen_tag} (revisão ${chosen_rev})"
}

# -----------------------------------------------------------------------------
# Menu principal
# -----------------------------------------------------------------------------
show_menu() {
  header "ECS Manager — Projeto BIA"
  echo -e "  ${BOLD}1)${RESET} Deploy    — Build, push e deploy com o commit atual"
  echo -e "  ${BOLD}2)${RESET} Rollback  — Selecionar e aplicar uma versão anterior"
  echo -e "  ${BOLD}3)${RESET} Listar    — Exibir versões disponíveis na task definition"
  echo -e "  ${BOLD}4)${RESET} Sair"
  echo ""
}

# -----------------------------------------------------------------------------
# Entrypoint principal
# -----------------------------------------------------------------------------
main() {
  check_dependencies
  check_git_repo
  read_parameters

  while true; do
    show_menu

    read -rp "$(echo -e "${CYAN}Escolha uma ação [1-4]: ${RESET}")" action
    echo ""

    case "$action" in
      1) action_deploy   ;;
      2) action_rollback ;;
      3) action_list     ;;
      4)
        info "Saindo. Até logo!"
        exit 0
        ;;
      *)
        warn "Opção inválida. Escolha entre 1 e 4."
        ;;
    esac

    echo ""
    read -rp "$(echo -e "${CYAN}Pressione ENTER para voltar ao menu...${RESET}")" _
  done
}

main "$@"
