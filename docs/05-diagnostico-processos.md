# 05 — O que mantém um dispositivo ocupado

`bigmount --busy ALVO` e o diálogo de remoção segura juntam:

1. **Processos** — `lsof -w -F pcuLftan -- PONTO` (saída por campos, a
   interface estruturada do lsof). Para cada arquivo: PID, usuário, comando,
   descritor (`cwd`, `rtd`, `txt`, `mem` ou número), modo (`r`/`w`/`u`) e
   caminho. Estado e horário de início vêm de `/proc/PID/stat`.
2. **Sem processo** — outras montagens do mesmo dispositivo, montagens
   aninhadas, arquivo de swap, imagem de disco ligada a um loop,
   holders de device-mapper/RAID.

Nomes amigáveis: Dolphin, kioworker pelo protocolo (`thumbnail`, `trash`,
`file`), Baloo, terminais, shells, players, indexadores, cópia,
sincronização, backup. A tabela mostra o nome amigável com o nome técnico
embaixo, o PID e a atividade ("Pasta atual está no dispositivo", "Aberto para
leitura", "Aberto para escrita"). Nunca mostra porcentagem, velocidade ou
tempo restante: um arquivo aberto não é uma transferência.

## Por que a mensagem genérica do Plasma aparece

O applet "Discos e dispositivos" do Plasma 6 já roda `lsof` como usuário
quando a desmontagem falha (verificado em `org.kde.plasma.devicenotifier.so`)
e cita o aplicativo quando o encontra. A frase genérica "um ou mais arquivos
estão abertos" aparece quando o responsável é invisível para o usuário:

- processo de root ou de outro usuário;
- uma segunda montagem. Nesta máquina, `sda1` está em `/mnt/Dados` **e** em
  `/var/lib/os-prober/mount` (sobra do os-prober);
- swap, loop ou montagem aninhada.

O Big-Mount mostra esses casos. Quando nenhum processo do usuário aparece, o
diálogo oferece **"Mostrar programas de todos os usuários (administrador)"**.
Essa opção roda, via `pkexec`, apenas `/usr/lib/big-mount/bigmount-holders`:
um auxiliar somente leitura, com ação Polkit própria, que valida que o
argumento é um ponto de montagem exato de um dispositivo de bloco local.

## Integração com o Dolphin

O Plasma não oferece um ponto de extensão suportado para acrescentar ações à
falha de desmontagem, e o Big-Mount não intercepta nem altera o Dolphin. A
alternativa implementada:

- menu de contexto do Dolphin (`usr/share/kio/servicemenus/big-mount.desktop`),
  submenu "Dispositivo de armazenamento": "Por que não consigo gravar aqui?"
  e "Remover com segurança (mostra o que o mantém ocupado)";
- lançador "Diagnóstico de Armazenamento" no menu de aplicativos;
- a ferramenta faz `cd /` antes de tudo para não ocupar o dispositivo que
  deve liberar.

**Não validado na interface real**: o menu de contexto e os diálogos KDialog
precisam de teste manual no Plasma (ver `09-testes.md`).
