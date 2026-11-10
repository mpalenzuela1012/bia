#!/usr/bin/env bash
#
# ssm-rds-tunnel.sh
#
# Abre um túnel SSM (AWS-StartPortForwardingSessionToRemoteHost) até uma
# instância RDS, usando uma instância EC2 como ponte (bastion). A EC2 ponte é
# ligada somente quando necessário e, ao encerrar o túnel (CTRL+C), o script
# pergunta se deseja desligá-la. O RDS não é ligado nem desligado pelo script:
# ele deve estar disponível ('available').
#
# Uso:
#   ./ssm-rds-tunnel.sh <NOME_DA_EC2> <NOME_DO_RDS> [<PROFILE_AWS>]
#
# Parâmetros:
#   1) <NOME_DA_EC2>   obrigatório - valor da tag "Name" da instância EC2 ponte
#   2) <NOME_DO_RDS>   obrigatório - identificador (DBInstanceIdentifier) do RDS
#   3) <PROFILE_AWS>   opcional    - profile do AWS CLI (ex.: o usado no aws login)
#
# Variáveis de ambiente opcionais:
#   LOCAL_PORT   porta local do túnel (padrão: a mesma porta do RDS)
#   WAIT_EC2     segundos de espera após ligar a EC2 (padrão: 60); a espera se
#                repete até a EC2 ficar 'running'
#
# Ordem de execução:
#   1) consulta o RDS (status e endpoint) e interrompe se ele não estiver
#      utilizável;
#   2) liga a EC2 (se estiver desligada) e aguarda o tempo de espera, que serve
#      para o estabelecimento da conexão SSM. Se a EC2 ainda não estiver
#      'running' ao fim da espera, a espera se repete até que fique nesse estado;
#   3) abre o túnel;
#   4) ao encerrar o túnel (CTRL+C), pergunta se deseja desligar a EC2 (Enter
#      confirma o padrão, que é Sim). Se o desligamento falhar, a pergunta se
#      repete.
#
# Exemplo:
#   LOCAL_PORT=5433 ./ssm-rds-tunnel.sh minha-ec2-ponte meu-rds meu-profile
#   (depois, em outro terminal: psql -h 127.0.0.1 -p 5433 -U <USUARIO> -d <BANCO>)
#
# Requisitos: AWS CLI v2, Session Manager Plugin e credenciais válidas
# (aws login). A instância EC2 precisa ser gerenciada pelo SSM.

set -uo pipefail

WAIT_EC2="${WAIT_EC2:-60}"
LOCAL_PORT="${LOCAL_PORT:-}"

uso() {
  cat <<EOT
Uso: $(basename "$0") <NOME_DA_EC2> <NOME_DO_RDS> [<PROFILE_AWS>]

  NOME_DA_EC2   (obrigatório) valor da tag Name da instância EC2 ponte
  NOME_DO_RDS   (obrigatório) identificador da instância RDS
  PROFILE_AWS   (opcional)    profile do AWS CLI

Variáveis opcionais: LOCAL_PORT (padrão: porta do RDS), WAIT_EC2 (60)
EOT
}

info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
erro() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

# Espera N segundos mostrando a contagem regressiva. A linha traz o horário em
# que a espera começou e, ao final, o horário em que ela terminou.
aguardar() {
  local total="$1" texto="$2" restante inicio
  inicio="$(date +%H:%M:%S)"
  for ((restante = total; restante > 0; restante--)); do
    printf '\r[%s] %s: %3ds restantes ' "$inicio" "$texto" "$restante"
    sleep 1
  done
  printf '\r[%s] %s: concluído.%20s\n' "$(date +%H:%M:%S)" "$texto" ""
}

# Espera o que falta de um tempo total contado a partir de um instante inicial
# (em segundos desde a época). Se o tempo já passou, não espera.
aguardar_restante() {
  local inicio="$1" total="$2" texto="$3" restante
  restante=$((total - ($(date +%s) - inicio)))
  if ((restante > 0)); then
    aguardar "$restante" "$texto"
  fi
}

# Pergunta Sim (S) ou Não (N). Enter confirma o padrão (Sim).
# Retorna 0 para Sim e 1 para Não. Se a leitura for interrompida (CTRL+C ou
# fim da entrada), assume Não.
perguntar_sn() {
  local pergunta="$1" resp
  while true; do
    if ! read -r -p "${pergunta} Sim (S) ou Não (N) [padrão: S]: " resp; then
      echo
      echo "Leitura interrompida; assumindo Não (N)."
      return 1
    fi
    case "${resp,,}" in
      "" | s | sim) return 0 ;;
      n | nao | não) return 1 ;;
      *) echo "Responda com S ou N (Enter = S)." ;;
    esac
  done
}

# ---------------------------------------------------------------- parâmetros
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  uso
  exit 0
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
  uso >&2
  exit 1
fi

EC2_NAME="$1"
RDS_NAME="$2"
PROFILE="${3:-}"

AWS=(aws)
if [[ -n "$PROFILE" ]]; then
  AWS+=(--profile "$PROFILE")
fi

# ------------------------------------------------------------- pré-requisitos
command -v aws >/dev/null 2>&1 || erro "AWS CLI não encontrado no PATH."
command -v session-manager-plugin >/dev/null 2>&1 || erro "Session Manager Plugin não encontrado no PATH."

"${AWS[@]}" sts get-caller-identity >/dev/null 2>&1 ||
  erro "Credenciais inválidas ou expiradas. Execute: aws login${PROFILE:+ --profile $PROFILE}"

# ------------------------------------------------- Status e Endpoint do RDS
RDS_STATUS="" RDS_ENDPOINT="" RDS_PORT=""
saida=$("${AWS[@]}" rds describe-db-instances \
  --db-instance-identifier "$RDS_NAME" \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,Endpoint.Port]' \
  --output text 2>&1) ||
  erro "Não foi possível consultar a instância RDS '${RDS_NAME}': ${saida}"
read -r RDS_STATUS RDS_ENDPOINT RDS_PORT <<<"$saida"
[[ "$RDS_ENDPOINT" == "None" ]] && RDS_ENDPOINT=""
[[ "$RDS_PORT" == "None" ]] && RDS_PORT=""
info "RDS '${RDS_NAME}' -> status: ${RDS_STATUS}; endpoint: ${RDS_ENDPOINT:-(indisponível)}"

# O RDS não é gerenciado por este script: precisa estar utilizável.
case "$RDS_STATUS" in
  available) ;;
  stopped | stopping | starting | failed | deleting | deleted | storage-full | \
    incompatible-* | restore-error | inaccessible-encryption-credentials*)
    erro "O RDS está com status '${RDS_STATUS}' e não aceita conexões. Verifique a instância no console."
    ;;
  *)
    info "O RDS está com status '${RDS_STATUS}'; seguindo, mas a conexão pode falhar."
    ;;
esac

[[ -n "$RDS_ENDPOINT" && -n "$RDS_PORT" ]] ||
  erro "Endpoint do RDS indisponível (status: ${RDS_STATUS})."

# --------------------------------------------------- ID da instância EC2 (tag Name)
EC2_IDS=$("${AWS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=${EC2_NAME}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text) ||
  erro "Falha ao consultar as instâncias EC2."

read -r -a EC2_LISTA <<<"$EC2_IDS"
if [[ ${#EC2_LISTA[@]} -eq 0 ]]; then
  erro "Nenhuma instância EC2 encontrada com a tag Name '${EC2_NAME}'."
elif [[ ${#EC2_LISTA[@]} -gt 1 ]]; then
  erro "Mais de uma instância EC2 com a tag Name '${EC2_NAME}': ${EC2_LISTA[*]}"
fi
EC2_ID="${EC2_LISTA[0]}"

consultar_ec2() {
  EC2_ESTADO=$("${AWS[@]}" ec2 describe-instances --instance-ids "$EC2_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text) ||
    erro "Falha ao consultar o estado da EC2."
}

consultar_ec2
info "EC2 '${EC2_NAME}' -> status: ${EC2_ESTADO}; id: ${EC2_ID}"

# ------------------------------------------------------------- Ligar a EC2
EC2_LIGOU=0
EC2_T0=0

case "$EC2_ESTADO" in
  running)
    info "EC2 já está ligada."
    ;;
  stopped | stopping)
    if [[ "$EC2_ESTADO" == "stopping" ]]; then
      info "EC2 está desligando; aguardando o desligamento para ligá-la novamente..."
      "${AWS[@]}" ec2 wait instance-stopped --instance-ids "$EC2_ID" ||
        erro "A EC2 não chegou ao estado 'stopped'."
    fi
    info "Ligando a EC2 ${EC2_ID}..."
    "${AWS[@]}" ec2 start-instances --instance-ids "$EC2_ID" >/dev/null ||
      erro "Falha ao ligar a EC2."
    EC2_LIGOU=1
    EC2_T0=$(date +%s)
    ;;
  pending)
    info "EC2 já está iniciando."
    EC2_LIGOU=1
    EC2_T0=$(date +%s)
    ;;
  *)
    erro "Estado inesperado da EC2: ${EC2_ESTADO}"
    ;;
esac

# ------------------------------------------------ Espera (conexão SSM)
if ((EC2_LIGOU)); then
  aguardar_restante "$EC2_T0" "$WAIT_EC2" "Aguardando o EC2 para a conexão SSM"
  consultar_ec2
  # Repete a espera até a EC2 ficar 'running' (CTRL+C interrompe o script).
  while [[ "$EC2_ESTADO" != "running" ]]; do
    case "$EC2_ESTADO" in
      stopping | stopped | shutting-down | terminated)
        erro "A EC2 entrou no estado '${EC2_ESTADO}' e não ficará 'running' sozinha. Verifique a instância no console."
        ;;
    esac
    info "A EC2 ainda está com status '${EC2_ESTADO}'. Repetindo a espera até ela ficar 'running'."
    aguardar "$WAIT_EC2" "Aguardando o EC2 para a conexão SSM"
    consultar_ec2
  done
  info "EC2 disponível (status: ${EC2_ESTADO})."
fi

# ------------------------------------------------------- Porta local do túnel
LOCAL_PORT="${LOCAL_PORT:-$RDS_PORT}"
if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :${LOCAL_PORT}" | tail -n +2 | grep -q .; then
  erro "A porta local ${LOCAL_PORT} já está em uso. Use outra: LOCAL_PORT=<PORTA> $(basename "$0") ..."
fi

# ----------------------------------------------------- Túnel SSM até o RDS
echo
info "Abrindo o túnel: 127.0.0.1:${LOCAL_PORT} -> ${RDS_ENDPOINT}:${RDS_PORT} (via ${EC2_ID})"
info "Conecte o cliente do banco em 127.0.0.1:${LOCAL_PORT}. Pressione CTRL+C para encerrar o túnel."
echo

# O trap evita que o CTRL+C encerre o script; o filho (aws/plugin) recebe o
# CTRL+C normalmente e termina a sessão, e o script segue para a pergunta.
trap ':' INT

"${AWS[@]}" ssm start-session \
  --target "$EC2_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${RDS_ENDPOINT}\"],\"portNumber\":[\"${RDS_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
SSM_RC=$?

echo
info "Sessão SSM encerrada (código de saída: ${SSM_RC})."
echo

# ------------------------------------------------------------- Desligar a EC2
# Se o desligamento falhar, a pergunta se repete (responda N para seguir adiante).
desligar_ec2() {
  local novo_estado
  while perguntar_sn "Deseja desligar a instância EC2 '${EC2_NAME}' (${EC2_ID})?"; do
    info "Desligando a EC2 ${EC2_ID}..."
    if novo_estado=$("${AWS[@]}" ec2 stop-instances --instance-ids "$EC2_ID" \
      --query 'StoppingInstances[0].CurrentState.Name' --output text); then
      info "EC2: estado ${novo_estado}."
      return 0
    fi
    info "Não foi possível desligar a EC2 (veja a mensagem acima). A pergunta será repetida."
    echo
  done
  info "EC2 mantida ligada."
}

desligar_ec2

info "Concluído."
