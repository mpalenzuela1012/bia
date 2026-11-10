SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function build_react {
    cd ./bia
    echo "  Iniciando build..."
#    cp ./client/package.json .
    cd client && npm install --legacy-peer-deps --loglevel=error
    VITE_API_URL=http://54.172.170.161 npm run build
    echo "  Build finalizado."
}

function deploy_s3 {
    local bucket="innovsysti-dev-desafio3"
    local build_dir="$SCRIPT_DIR/bia/client/build"

    if [ ! -d "$build_dir" ]; then
        echo "  Pasta $build_dir nao encontrada. Execute o build antes."
        return 1
    fi

    echo "  Copiando build para s3://$bucket ..."
    aws s3 sync "$build_dir" "s3://$bucket" --delete --profile 704298683792 || return 1
    echo "  Deploy finalizado."
}

build_react
deploy_s3
