# 🧞 Genius Windows Toolkit

Utilitário PowerShell de bancada para **pós-formatação do Windows**, com interface gráfica moderna e arquitetura inspirada no [WinUtil do Chris Titus](https://github.com/christitustech/winutil): todas as operações pesadas rodam em *runspaces* em segundo plano — a janela nunca congela — com log em tempo real, barra de progresso real e backup antes de qualquer alteração.

## Execução rápida (PowerShell)

```powershell
irm https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/GeniusToolkit.ps1 | iex
```

Com parâmetros:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/GeniusToolkit.ps1))) -TargetDrive D: -Preset Extended
```

Aplicando um preset salvo (arquivo local ou URL):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/GeniusToolkit.ps1))) -Config 'C:\presets\bancada.json'
```

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

Catálogo estilo Ninite com IDs validados e sem duplicatas: navegadores, mensageria, compactadores, mídia, VC++ Redistributables, .NET, Java (Temurin), imagem, utilitários de bancada (CPU-Z, HWiNFO, CrystalDiskInfo, AnyDesk, RustDesk...), documentos, segurança e desenvolvimento.

- Busca instantânea, botões **Kit básico / Tudo / Limpar**
- Instalação silenciosa com resumo final (instalados × falhas)
- **Atualizar tudo** (`winget upgrade --all`) em um clique

## ⚙️ Ajustes do Windows

Extensões de arquivos, arquivos ocultos, histórico da área de transferência (Win+V), Explorer em "Este Computador", modo escuro, menu de contexto clássico do Windows 11, remover Bing da busca, barra de tarefas à esquerda, botão "Finalizar tarefa" e desativar inicialização rápida — sempre com backup `.reg` antes.

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

## Créditos

- Arquitetura de runspaces + presets inspirada no [WinUtil](https://github.com/christitustech/winutil) (MIT) de Chris Titus.
- Licença: [MIT](LICENSE).
