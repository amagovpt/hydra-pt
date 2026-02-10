import os
import subprocess
import sys
from datetime import datetime

# --- CONFIGURAÇÕES ---
DB_HOST = "localhost"
DB_PORT = "5434"  # "5434" ou "5432"
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


def realizar_backup():
    """Cria um backup da base de dados."""
    verificar_diretorio()

    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    filename = f"backup_{timestamp}.dump"
    file_path = os.path.join(BACKUP_DIR, filename)

    print(f"\n🔄 [BACKUP] Iniciando cópia de '{DB_NAME}'...")

    comando = [
        "pg_dump",
        "-h",
        DB_HOST,
        "-p",
        DB_PORT,
        "-U",
        DB_USER,
        "-F",
        "c",  # Formato Custom (comprimido)
        "-f",
        file_path,
        DB_NAME,
    ]

    env_vars = os.environ.copy()
    env_vars["PGPASSWORD"] = DB_PASS

    try:
        subprocess.run(comando, env=env_vars, check=True)
        print(f"✅ [SUCESSO] Backup criado: {filename}")
        print(f"   Caminho completo: {os.path.abspath(file_path)}")
    except subprocess.CalledProcessError as e:
        print(f"❌ [ERRO] Falha ao realizar backup: {e}")


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
        if choice == 0:
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

    print(
        f"\n⚠️  [PERIGO] Você está prestes a restaurar: {os.path.basename(arquivo_alvo)}"
    )
    print(f"   Isso irá SOBRESCREVER os dados atuais da base '{DB_NAME}'.")
    confirmacao = input(
        "   Tem certeza que deseja continuar? (digite 'SIM' para confirmar): "
    )

    if confirmacao != "SIM":
        print("🛑 Operação cancelada pelo usuário.")
        return

    print(f"\n🔄 [RESTORE] Restaurando base de dados...")

    # Comando pg_restore com a flag -c (clean) para limpar antes de criar
    comando = [
        "pg_restore",
        "-h",
        DB_HOST,
        "-p",
        DB_PORT,
        "-U",
        DB_USER,
        "-d",
        DB_NAME,
        "-c",
        arquivo_alvo,
    ]

    env_vars = os.environ.copy()
    env_vars["PGPASSWORD"] = DB_PASS

    try:
        # stderr=subprocess.DEVNULL esconde avisos não críticos do postgres,
        # remova se quiser ver o log completo.
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
