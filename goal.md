# 🔐 Escrow Contract — Metas del Proyecto

> Proyecto original de portafolio. Demuestra lógica de negocio real conectada con experiencia fintech.

---

## 🎯 ¿Qué es este proyecto?

Un contrato de custodia (escrow) descentralizado donde:

- Un **comprador** deposita ETH en el contrato
- Un **vendedor** entrega un servicio o producto
- Un **árbitro** resuelve disputas si las hay
- El contrato libera o reembolsa los fondos según el resultado

---

## ✅ Checklist de metas

### Fase 1 — Contrato base

- [x] Crear repo `defi-escrow` con estructura Foundry
  - `src/Escrow.sol`
  - `test/unit/EscrowTest.t.sol`
  - `script/DeployEscrow.s.sol`
  - `script/HelperConfig.s.sol`
  - `README.md`
- [x] Definir los 3 roles: `buyer`, `seller`, `arbiter`
- [x] Función `deposit()` — solo el buyer puede depositar ETH
- [x] Estado del contrato con `enum State { AWAITING_DELIVERY, COMPLETE, DISPUTED, REFUNDED }`
- [x] Función `confirmDelivery()` — buyer confirma entrega → fondos van al seller
- [x] ~~Función `refund()`~~ — cubierto por `resolveDispute(false)` y los timeouts
- [x] Función `resolveDispute(bool releaseToSeller)` — árbitro decide ganador
- [x] Función `openDispute()` — buyer o seller pueden abrir disputa
- [x] Timeout automático: si pasa X días sin acción, el buyer puede reclamar reembolso
- [x] Eventos para cada acción importante (`Deposited`, `DeliveryConfirmed`, `DisputeOpened`, `DisputeResolved`, `Refunded`)
- [x] Fee del protocolo (ej. 1%) deducido al liberar fondos → va a una dirección `owner`

---

### Fase 2 — Tests completos

- [x] Test: buyer deposita correctamente
- [x] Test: no-buyer no puede depositar
- [x] Test: buyer confirma entrega → seller recibe fondos menos fee
- [x] Test: árbitro resuelve a favor del seller
- [x] Test: árbitro resuelve a favor del buyer (refund)
- [x] Test: nadie puede abrir disputa antes del depósito
- [x] Test: timeout — buyer reclama reembolso después del plazo
- [x] Fuzz test: `resolveDispute` con diferentes amounts
- [x] Alcanzar **100% de coverage** con `forge coverage`

---

### Fase 3 — Scripts y deployment

- [x] `HelperConfig.s.sol` con configuración por red (local Anvil + Sepolia)
- [x] `DeployEscrow.s.sol` con script de deployment completo
- [x] Deploy en **Sepolia testnet**
- [x] Verificar contrato en Etherscan con `--verify`
- [x] Agregar dirección del contrato verificado al README

---

### Fase 4 — CI/CD y calidad

- [x] GitHub Actions: `forge fmt --check` + `forge build` + `forge test` en cada push
- [x] `.env.example` con variables necesarias
- [x] `.gitignore` correcto (no subir `.env`)
- [x] `Makefile` con comandos: `deploy`, `test`, `coverage`, `verify`
- [x] Gas snapshot con `forge snapshot`

---

### Fase 5 — README profesional

- [x] Descripción clara del proyecto y por qué existe
- [x] Diagrama del flujo (texto o imagen)
- [x] Tech stack table
- [x] Instrucciones de instalación y uso
- [x] Cómo correr los tests
- [x] Dirección deployada en Sepolia con link a Etherscan
- [x] Sección de **Security Notes** con limitaciones conocidas
- [x] Sección de posibles mejoras futuras

---

### Fase 6 — Nivel profesional (v3)

- [x] Timeout de disputa (`refundOnDisputeTimeout`): un árbitro ausente ya no puede bloquear fondos
- [x] `openDispute()` limitado al plazo de entrega (evita front-running del reembolso)
- [x] NatSpec completo en el contrato
- [x] Fuzz tests de propiedades (10) + invariant tests con handler y ghost variables (8)
- [x] Tests de integración del script de deploy (100% coverage también en `script/`)
- [x] Test de reentrancy con contrato atacante
- [x] Slither en CI (SARIF) + `SECURITY.md` con threat model y triage
- [x] Gate de coverage y `forge snapshot --check` en CI
- [x] Deploy con keystore cifrado (sin private key en texto plano)
- [x] Redeploy v3 en Sepolia y actualizar README

---

## 🔄 Flujo del contrato

```
Buyer deposita ETH
       ↓
  [AWAITING_DELIVERY]
       ↓
  ¿Entrega OK?
  ┌────┴────┐
 SÍ        NO
  ↓         ↓
buyer    buyer/seller
confirma  abre disputa
  ↓         ↓
[COMPLETE] [DISPUTED]
  ↓         ↓
seller   árbitro
recibe   resuelve
fondos    ↓      ↓
        seller  buyer
        recibe  recibe
        fondos  reembolso
```

---

## 💡 Features extra (opcionales para destacar más)

- [ ] Soporte multi-token (ERC-20 además de ETH nativo)
- [ ] Múltiples árbitros con votación (2 de 3)
- [ ] Historial de escrows por dirección

---

## 📦 Stack

| Capa | Herramienta |
|---|---|
| Lenguaje | Solidity `^0.8.19` |
| Framework | Foundry |
| Testing | Forge (unit + fuzz) |
| CI | GitHub Actions |
| Testnet | Sepolia |
| Verificación | Etherscan |

---

## 🗓️ Timeline sugerido

| Semana | Meta |
|---|---|
| Semana 1 | Fase 1 — Contrato base completo |
| Semana 2 | Fase 2 — Tests al 100% de coverage |
| Semana 3 | Fase 3 + 4 — Deploy, CI, Makefile |
| Semana 4 | Fase 5 — README + pulir detalles |