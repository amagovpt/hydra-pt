import os
import subprocess
import sys
from datetime import datetime

# --- CONFIGURAÇÕES ---
DB_HOST = "localhost"
DB_PORTS = ["5434", "5432"]

DB_NAME = "postgres"
DB_USER = "postgres"
# DICA: Em produção, use os.getenv("DB_PASSWORD")
DB_PASS = "postgres"

# Pasta onde os backups serão salvos
BACKUP_DIR = "./backups"


def verificar_diretorio():
    """Garante que a pasta de backups existe."""
    if not os.path.exists(BACKUP_DIR):
        os.makedirs(BACKUP_DIR)


def get_container_id(port):
    """Obtém o ID do container mapeado para a porta especificada."""
    try:
        # Lista containers formatados como "ID\tPortas"
        cmd = ["docker", "ps", "--format", "{{.ID}}\t{{.Ports}}"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        for line in result.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                cid, ports = parts[0], parts[1]
                # Verifica se a porta está mapeada (ex: 0.0.0.0:5432->5432)
                if f":{port}->" in ports:
                    return cid
    except Exception as e:
        print(f"⚠️  [AVISO] Não foi possível verificar containers Docker: {e}")
    return None


def realizar_backup():
    """Cria um backup da base de dados para cada porta configurada."""
    verificar_diretorio()
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")

    for port in DB_PORTS:
        filename = f"backup_{port}_{timestamp}.dump"
        file_path = os.path.join(BACKUP_DIR, filename)

        print(f"\n🔄 [BACKUP] Iniciando cópia de '{DB_NAME}' na porta {port}...")

        container_id = get_container_id(port)
        env_vars = os.environ.copy()
        env_vars["PGPASSWORD"] = DB_PASS

        try:
            if container_id:
                print(
                    f"   🐳 Container detectado ({container_id}). Executando via Docker..."
                )
                # Executa pg_dump dentro do container e captura a saída para o arquivo local
                # Nota: Não usamos -t (tty) para evitar problemas com stdout binário
                comando_docker = [
                    "docker",
                    "exec",
                    "-i",
                    container_id,
                    "pg_dump",
                    "-U",
                    DB_USER,
                    "-F",
                    "c",
                    DB_NAME,
                ]
                with open(file_path, "wb") as f_out:
                    subprocess.run(comando_docker, stdout=f_out, check=True)

            else:
                print("   🖥️  Rodando pg_dump localmente...")
                comando = [
                    "pg_dump",
                    "-h",
                    DB_HOST,
                    "-p",
                    port,
                    "-U",
                    DB_USER,
                    "-F",
                    "c",
                    "-f",
                    file_path,
                    DB_NAME,
                ]
                subprocess.run(comando, env=env_vars, check=True)

            print(f"✅ [SUCESSO] Backup criado: {filename}")
            print(f"   Caminho completo: {os.path.abspath(file_path)}")

        except subprocess.CalledProcessError as e:
            print(f"❌ [ERRO] Falha ao realizar backup na porta {port}: {e}")


def listar_e_selecionar_backup():
    """Lista os arquivos na pasta e retorna o caminho do escolhido."""
    verificar_diretorio()

    # Lista apenas arquivos .dump
    arquivos = [f for f in os.listdir(BACKUP_DIR) if f.endswith(".dump")]

    if not arquivos:
        print("\n⚠️  Nenhum arquivo de backup encontrado na pasta './backups'.")
        return None

    # Ordena do mais recente para o mais antigo
    arquivos.sort(reverse=True)

    print("\n📂 --- ARQUIVOS DE BACKUP DISPONÍVEIS ---")
    for index, arquivo in enumerate(arquivos):
        print(f"  [{index + 1}] {arquivo}")
    print("-----------------------------------------")

    try:
        escolha = int(
            input("Digite o número do arquivo para restaurar (0 para cancelar): ")
        )
        if escolha == 0:
            return None

        if 1 <= escolha <= len(arquivos):
            return os.path.join(BACKUP_DIR, arquivos[escolha - 1])
        else:
            print("❌ Opção inválida.")
            return None
    except ValueError:
        print("❌ Por favor, digite um número válido.")
        return None


def restaurar_backup():
    """Gerencia o fluxo de restauração."""
    arquivo_alvo = listar_e_selecionar_backup()

    if not arquivo_alvo:
        return

    print("\n🎯 Selecione a porta para restauração:")
    for index, port in enumerate(DB_PORTS):
        print(f"  [{index + 1}] {port}")

    try:
        p_escolha = int(input("Digite o número da porta: "))
        if 1 <= p_escolha <= len(DB_PORTS):
            target_port = DB_PORTS[p_escolha - 1]
        else:
            print("❌ Porta inválida.")
            return
    except ValueError:
        print("❌ Entrada inválida.")
        return

    print(
        f"\n⚠️  [PERIGO] Você está prestes a restaurar: {os.path.basename(arquivo_alvo)}"
    )
    print(
        f"   Isso irá SOBRESCREVER os dados atuais da base '{DB_NAME}' na porta {target_port}."
    )
    confirmacao = input(
        "   Tem certeza que deseja continuar? (digite 'SIM' para confirmar): "
    )

    if confirmacao != "SIM":
        print("🛑 Operação cancelada pelo usuário.")
        return

    print(f"\n🔄 [RESTORE] Restaurando base de dados na porta {target_port}...")

    container_id = get_container_id(target_port)
    env_vars = os.environ.copy()
    env_vars["PGPASSWORD"] = DB_PASS

    try:
        if container_id:
            print(
                f"   🐳 Container detectado ({container_id}). Executando via Docker..."
            )
            # pg_restore rodando dentro do container lendo do stdin
            comando_docker = [
                "docker",
                "exec",
                "-i",  # Interativo para aceitar stdin
                container_id,
                "pg_restore",
                "-U",
                DB_USER,
                "-d",
                DB_NAME,
                "-c",
                # Sem nome de arquivo, lê do stdin
            ]

            with open(arquivo_alvo, "rb") as f_in:
                subprocess.run(comando_docker, stdin=f_in, check=True)
        else:
            print("   🖥️  Rodando pg_restore localmente...")
            comando = [
                "pg_restore",
                "-h",
                DB_HOST,
                "-p",
                target_port,
                "-U",
                DB_USER,
                "-d",
                DB_NAME,
                "-c",
                arquivo_alvo,
            ]
            subprocess.run(comando, env=env_vars, check=True)

        print("✅ [SUCESSO] Base de dados restaurada com sucesso!")
    except subprocess.CalledProcessError as e:
        print(f"❌ [ERRO] Falha na restauração: {e}")


def menu_principal():
    while True:
        print("\n" + "=" * 30)
        print("   🐘 POSTGRES MANAGER v1.0")
        print("=" * 30)
        print("1. 💾 Fazer Backup (Dump)")
        print("2. ♻️  Restaurar Backup (Restore)")
        print("3. 🚪 Sair")
        print("-" * 30)

        opcao = input("Escolha uma opção: ")

        if opcao == "1":
            realizar_backup()
        elif opcao == "2":
            restaurar_backup()
        elif opcao == "3":
            print("Saindo... Até logo!")
            sys.exit()
        else:
            print("❌ Opção inválida, tente novamente.")


if __name__ == "__main__":
    try:
        menu_principal()
    except KeyboardInterrupt:
        print("\n\nOperação interrompida. Saindo...")
