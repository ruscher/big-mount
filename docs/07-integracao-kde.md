# 07 — Integração com o KDE Plasma (e GNOME)

## Fronteira de privilégio

```
boot (root)                         sessão do usuário (nunca root)
big-mount.service ── escreve ──>  /run/big-mount/status ── lê ──> bigmount --notifier
                                                                    │ notify-send (D-Bus)
                                                                    └ KDialog/Zenity
```

O serviço de boot não abre interface nem fala com a sessão. Ele deixa um
arquivo de estado (`DEVICE UUID MOUNTPOINT STATE REASON`). O notificador da
sessão lê esse arquivo e reage a eventos de montagem com `findmnt --poll`: o
kernel acorda o processo, sem nenhuma varredura periódica.

| Mecanismo | Uso | Motivo |
|---|---|---|
| Notificações freedesktop (`notify-send`, desktop-entry `big-mount`) | "Dispositivo montado somente para leitura" com **Ver detalhes**, **Como resolver** e, só quando existe correção segura, **Tentar corrigir** | Plasma 6 e GNOME exibem nativamente; não bloqueiam |
| KDialog | diagnóstico, dispositivo ocupado, confirmações | já instalado no Plasma; tema, modo escuro, HiDPI e leitor de tela vêm do Qt |
| Zenity | as mesmas janelas na edição GNOME | — |
| Terminal | tudo funciona sem interface gráfica | requisito do projeto |

Avaliei Qt/Kirigami (PySide6 ou QML): dariam uma janela única com
atualização ao vivo, mas acrescentariam centenas de MB de dependências a um
pacote de shell. O KDialog cobre os casos com uma tabela HTML. A janela é
reaberta ao atualizar, que é o custo dessa escolha.

Anti-repetição: no máximo uma notificação por dispositivo e causa a cada
boot (`~/.local/state/big-mount/notified`, chaveado pelo `boot_id`). CDs,
DVDs e imagens não geram aviso. Montagens bem-sucedidas não geram
notificação, porque o Plasma já comunica isso.

## Verificação visual

Os diálogos foram renderizados fora da tela com Qt (`QMessageBox`, estilo
Fusion, escala 2×, paleta clara e escura, inglês e português). Isso levou a
mudar a tabela: o nome técnico foi para uma segunda linha e só a coluna PID
deixou de quebrar, porque antes o texto era cortado.

Também foi verificado:

- o `kdialog` real (26.08, plataforma offscreen) aceita cada forma de chamada
  do código: `--warningyesnocancel`, `--warningyesno`, `--msgbox`,
  `--sorry`, `--error`, `--menu` e `--textbox`, com `--title`, `--icon` e
  rótulos de botões. Uma opção inválida sai com 1; as válidas ficam esperando
  o usuário;
- o `zenity` real (4.2.2) tem todas as opções usadas;
- os fluxos completos (ocupado → mais opções → fechar programas → removido;
  cancelar; sistema recusado; montar de novo com gravação; dispositivo
  protegido sem botão de correção) passam com cliques roteirizados.

Falta conferir visualmente no Plasma real: tema Breeze, escala e leitor de
tela.

## Memória e CPU do notificador

Medido: `bash` 6,1 MB + `findmnt --poll` 3,5 MB de RSS, 0 s de CPU parado.
Pode ser desativado em Configurações do Sistema → Inicialização automática.
