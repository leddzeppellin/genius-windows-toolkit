<p align="center">
  <img src="assets/genius-info-logo.png" alt="Genius Info — Soluções em Tecnologia" width="440"/>
</p>

<h1 align="center">Genius Windows Toolkit</h1>

<p align="center">
  <em>Ferramenta de bancada para pós-formatação do Windows</em><br/>
  <sub>por Ricardo Valério S. · Genius Info</sub>
</p>

---

Utilitário PowerShell de bancada para **pós-formatação do Windows**, com interface gráfica moderna: todas as operações pesadas rodam em *runspaces* em segundo plano — a janela nunca congela — com log em tempo real, barra de progresso real e backup antes de qualquer alteração.

## Execução rápida (PowerShell)

Abra o PowerShell e rode:

```powershell
irm https://bit.ly/genius-toolkit | iex
```

Com parâmetros (unidade de destino, preset inicial):

```powershell
& ([scriptblock]::Create((irm https://bit.ly/genius-toolkit))) -TargetDrive D: -Preset Extended
```

Aplicando um preset salvo (arquivo local ou URL):

```powershell
& ([scriptblock]::Create((irm https://bit.ly/genius-toolkit))) -Config 'C:\presets\bancada.json'
```

O link curto `bit.ly/genius-toolkit` aponta para o carregador `get.ps1`. Se preferir a URL completa, use `https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/get.ps1`.

## 💾 Uso offline (pendrive)

Para levar numa bancada sem internet, baixe o `.zip` da [página de releases](https://github.com/leddzeppellin/genius-windows-toolkit/releases) (ou os arquivos do repositório) e copie para o pendrive. Depois é só **dar duplo-clique**:

| Arquivo | Para quê |
|---|---|
| **`Genius-Toolkit-Admin.bat`** | Abre já como Administrador (pede UAC). **Recomendado** — libera as abas Rede, Recursos, Windows Update e Criar ISO. |
| `Genius-Toolkit.bat` | Abre sem elevação (migração de pastas e ajustes de usuário). |
| `GeniusToolkit.ps1` | O app em si (os `.bat` chamam este arquivo). |

Os `.bat` já cuidam do `ExecutionPolicy` — não precisa abrir o PowerShell nem digitar nada.

**O que funciona 100% offline:** migração de pastas, reparo de rede, ajustes, privacidade e debloat, diagnóstico, e **modificar/gravar uma ISO** que já esteja no pendrive.

**O que precisa de internet:** instalar/atualizar programas (winget baixa da rede), baixar o `oscdimg` para *exportar* a ISO (se o Windows ADK não estiver instalado) e ativar alguns recursos como o .NET 3.5. O app detecta a ausência de internet e avisa no log quais recursos ficam indisponíveis.

> ℹ️ O `get.ps1` é um carregador minúsculo em ASCII puro: ele baixa o `GeniusToolkit.ps1` (UTF-8 com BOM, acentuação e ícones corretos), remove o caractere BOM que o `irm` preserva — e que quebraria o `iex` — e executa repassando seus argumentos. Para uso local, rode o `GeniusToolkit.ps1` diretamente.

## 📁 Migração de pastas do usuário

Migra as pastas conhecidas do perfil (Documentos, Imagens, Músicas, Vídeos, Downloads, Área de Trabalho e outras) para outra unidade usando a API oficial `SHSetKnownFolderPath` — o mesmo mecanismo da guia "Local" nas propriedades da pasta, sem editar registro na mão.

Proteções embutidas:

- **Análise prévia obrigatória**: mede o tamanho real de cada pasta e **bloqueia a migração se não houver espaço suficiente** no destino (com folga de 5%).
- **Cópia verificada**: depois do robocopy, uma passada de verificação confere origem × destino; o atalho **só é redirecionado se a cópia estiver íntegra**.
- **Progresso real**: bytes copiados alimentam a barra de progresso; nada de janela "Não respondendo".
- **Backup automático**: JSON com os caminhos atuais + exportação `.reg` de `User Shell Folders` e `Shell Folders` antes de qualquer mudança.
- **A origem nunca é apagada.** Opcionalmente ela é *renomeada* para `NOME-old-DATA` após a verificação, para não sobrar duas pastas "Documentos" no Explorer.
- **Detecção de OneDrive** e aviso quando a sessão está elevada com outro usuário (evita migrar o perfil errado).

## 🌐 Reparo de rede e compartilhamento

Rotina completa para redes legadas (NAS, DVR, impressoras antigas, compartilhamento entre máquinas), com backup `.reg` das chaves HKLM antes de executar e cada ação isolada (uma falha não interrompe as demais):

- NetBIOS sobre TCP/IP nos adaptadores ativos
- SMB 1.0/CIFS (opcional)
- Logon convidado inseguro SMB e assinatura SMB
- Perfil de rede como Particular
- Chaves LSA para compartilhamento sem senha
- Regras de firewall de descoberta/compartilhamento **por grupo nativo** (funciona em qualquer idioma do Windows, com fallback via `netsh`)
- Serviços de compartilhamento em modo Automático
- Flush DNS, reset TCP/IP e reset Winsock (opcional)

> ⚠️ **Aviso**: SMB1, logon convidado inseguro e compartilhamento sem senha reduzem a segurança do Windows. Use apenas quando precisar de compatibilidade com equipamentos legados, preferencialmente em redes confiáveis. O toolkit cria backups `.reg` antes das mudanças, mas a decisão de aplicar cada ajuste é do técnico.

## 📦 Programas (winget)

Catálogo amplo (mais de 200 programas) organizado em categorias: Navegadores, Comunicação, Multimídia, Utilitários, Ferramentas Pro (redes, VPN, benchmark), Ferramentas Microsoft (Sysinternals, PowerToys, runtimes), Desenvolvimento, Jogos, Self-hosted e **Backup e Segurança** (Hasleo Backup Suite, Malwarebytes, AdwCleaner). Instala tanto do repositório winget quanto da Microsoft Store (`msstore`).

- Busca instantânea, botões **Kit básico / Tudo / Limpar**
- Instalação silenciosa com resumo final (instalados × falhas)
- **Desinstalar** os programas marcados e **Detectar instalados** (marca no catálogo o que já está na máquina)
- **Atualizar tudo** (`winget upgrade --all`) em um clique
- **Kit offline** — baixa os instaladores dos programas marcados para uma pasta `GeniusOfflineKit\` (ao lado do app, no pendrive) e salva um perfil `kit.json`. Depois, em qualquer máquina **sem internet**, o botão **Instalar do kit offline** invoca os instaladores locais em modo silencioso. Perfeito para montar um kit de bancada uma vez e reusar offline.
- **Verificar atualizações do kit** — compara a versão baixada de cada programa com a mais recente do winget, lista o que mudou (`v1.2 → v1.5`) e, se você confirmar, **baixa e substitui** só os instaladores desatualizados, mantendo o kit sempre em dia.

## 🛡️ Segurança das operações

- **Ponto de restauração automático** antes de aplicar Ajustes, Privacidade, Rede, Recursos, políticas de Windows Update e remoção de apps. Pode ser desligado no botão da barra lateral (com aviso no log).
- **Backup `.reg`** das chaves afetadas antes de cada alteração de registro.
- **Cancelar** uma operação em andamento: o botão aparece na barra de status e interrompe o processo após concluir o item atual.
- **Descrição em cada item**: passe o mouse sobre qualquer ajuste, item de privacidade, ação de rede, recurso do Windows ou opção da ISO para ver exatamente o que ele faz e quais os riscos.

## ⚙️ Ajustes

Preferências reversíveis de interface e sistema, em grade por categoria: extensões e arquivos ocultos, Explorer em "Este Computador", menu clássico do Windows 11, histórico da área de transferência (Win+V), modo escuro, barras de rolagem sempre visíveis, ajustes da barra de tarefas (alinhamento, botões, porcentagem da bateria), remover Bing da busca, ocultar "Recomendados" do Iniciar, logon verboso, BSoD detalhado, caminhos longos, pular tela de bloqueio, Num Lock ao iniciar, desativar aceleração do mouse e Teclas de Aderência, Game Mode, Outlook clássico e desativar inicialização rápida — sempre com backup `.reg` antes.

## 🧹 Privacidade e limpeza

Duas colunas: **tweaks** (Essenciais e Avançados) e **remoção de apps da Store**.

- **Essenciais**: desativar telemetria, histórico de atividades, recursos de consumidor, Delivery Optimization, rastreamento de localização, apps em segundo plano, hibernação; remover Widgets; WPBT; bloquear apps complementares de dispositivos; serviços não essenciais para Manual; bloquear recomendações da Store na busca; limpeza de disco e arquivos temporários.
- **Avançados (com cautela)**: debloat do Edge e do Brave, remover Edge/OneDrive, desativar e remover IA (Copilot/Recall), efeitos visuais para desempenho, Sensor de Armazenamento, notificações, Armazenamento Reservado, relógio em UTC (dual boot), remover Início e Galeria, preferir IPv4/desativar Teredo/IPv6, bloquear auto-instalação da Razer.
- **Remover apps da Store**: Feedback Hub, Teams, Office Hub, Copilot, Bing (News/Weather/Search), Xbox, Solitaire, Clipchamp, Dev Home, Power Automate e outros — para o usuário atual e novos usuários.

Botões de atalho **Só essenciais** e **Limpar**. Tudo com backup `.reg` antes.

## 🧩 Recursos e correções

- **Recursos do Windows**: .NET 3.5, Hyper-V, WSL, Windows Sandbox, cliente NFS, componentes de mídia legados, Telnet, backup diário do registro e recuperação por F8.
- **Correções rápidas**: reparar sistema (DISM + SFC), resetar o Windows Update, reinstalar o winget e corrigir o relógio (NTP).
- **Política de Windows Update**: Padrão (restaurar), Só segurança (mantém correções críticas, adia recursos por 1 ano, não reinicia com você logado) ou Desativar — com backup `.reg` antes.
- **DNS**: aplicar Google, Cloudflare (e variante que bloqueia malware), OpenDNS, Quad9 ou AdGuard nos adaptadores ativos — ou voltar ao automático.
- **Plano de energia**: ativar/remover o Desempenho Máximo.
- **Painéis clássicos**: atalhos para Painel de Controle, Gerenciador de Dispositivos, Serviços, Gerenciamento de Disco e outros.

## 🪟 Criar ISO (Windows 11 enxuto)

Gera uma ISO personalizada do Windows 11 a partir de uma imagem oficial, em quatro passos guiados:

1. **Selecionar** a ISO oficial (`.iso`).
2. **Montar e verificar** — lista as edições disponíveis (Home, Pro, etc.).
3. **Modificar** — copia a imagem, remove apps pré-instalados (Teams, Copilot, Office Hub, Xbox, Solitaire, Clipchamp, Dev Home e outros), desativa telemetria e sugestões e aplica **bypass dos requisitos** (TPM 2.0 / Secure Boot / CPU / RAM). Opcionalmente injeta os **drivers da máquina atual** e, marcando **"Pular OOBE"**, grava um `autounattend.xml` que pula toda a configuração inicial e cria uma **conta local Administrador** (nome à sua escolha, sem senha — defina depois), com locale pt-BR.
4. **Gerar a saída** — salvar como **arquivo ISO** (via `oscdimg`, instalado por winget se faltar) **ou gravar direto em um pendrive** (formata em FAT32/GPT e divide o `install.wim` automaticamente se passar de 4 GB). Ambas as opções mantêm só a edição escolhida.

> 🛡️ **Diferença importante**: ao contrário de outras ferramentas, a ISO gerada mantém o **Windows Update funcional** — não desativamos os serviços de atualização (evita entregar um sistema que nunca mais se atualiza). Requer Administrador, leva de 15 a 40 minutos e usa ~10 GB de disco temporário.

## 📡 Monitor de Internet

Na aba **Diagnóstico**, instala um monitor que mede a conexão sozinho de tempos em tempos usando o **Speedtest CLI da Ookla**:

- Mede **download, upload, ping, jitter e perda de pacotes** no intervalo que você escolher (15 a 1440 minutos, padrão 60)
- Roda como **tarefa agendada** sob a conta SYSTEM (não precisa de usuário logado nem senha)
- Guarda o histórico em `C:\InternetMonitor\data\historico-internet.csv` e mostra tudo num **painel local** (atalho na Área de Trabalho)
- Botões para **instalar**, **abrir o painel** e **desinstalar** (o histórico é preservado ao remover)
- Pode ser marcado no **preset**, para lembrar de instalá-lo nas próximas máquinas

Ótimo para diagnosticar reclamação de "internet lenta" em cliente: deixa medindo por alguns dias e depois mostra o gráfico. Os arquivos ficam em [`extras/InternetMonitor/`](extras/InternetMonitor).

## 🩺 Diagnóstico

Relatório com Windows, hardware, volumes, pastas conhecidas do perfil, adaptadores e perfis de rede — salvo em `%LOCALAPPDATA%\GeniusWindowsToolkit\reports`.

## 💾 Presets (várias máquinas, um clique)

Marque as pastas, ações de rede, ajustes e programas do seu kit e clique em **Exportar preset**. O toolkit salva um JSON e já copia para a área de transferência o comando pronto para reaplicar tudo em outra máquina:

```powershell
& ([scriptblock]::Create((irm .../GeniusToolkit.ps1))) -Config 'genius-preset.json'
```

Um exemplo está em [`presets/exemplo-bancada.json`](presets/exemplo-bancada.json).

## Pastas de trabalho

| Conteúdo | Local |
|---|---|
| Backups (`.reg` + JSON) | `%LOCALAPPDATA%\GeniusWindowsToolkit\backups` |
| Logs de sessão | `%LOCALAPPDATA%\GeniusWindowsToolkit\logs` |
| Relatórios de diagnóstico | `%LOCALAPPDATA%\GeniusWindowsToolkit\reports` |

## Quando precisa de Administrador?

| Não precisa | Precisa |
|---|---|
| Migrar pastas do usuário | Aba Rede (SMB, firewall, serviços, TCP/IP) |
| Instalar programas via winget | Desativar inicialização rápida |
| Ajustes de usuário (HKCU) | Restaurar backups de chaves HKLM |
| Diagnóstico e presets | |

O botão **"Abrir como Administrador"** reabre o toolkit elevado preservando a unidade e o preset selecionados.

## Desenvolvimento

```powershell
# Validar sintaxe + BOM UTF-8
powershell -File tools/check.ps1

# Smoke test (constrói a janela sem exibir)
powershell -File GeniusToolkit.ps1 -SmokeTest

# Teste de renderização (abre a janela por alguns segundos e fecha sozinha)
powershell -File tools/test-render.ps1
```

## Licença

Distribuído sob a licença [MIT](LICENSE).
