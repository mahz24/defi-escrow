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

- [ ] Crear repo `defi-escrow` con estructura Foundry
  - `src/Escrow.sol`
  - `test/unit/EscrowTest.t.sol`
  - `script/DeployEscrow.s.sol`
  - `script/HelperConfig.s.sol`
  - `README.md`
- [ ] Definir los 3 roles: `buyer`, `seller`, `arbiter`
- [ ] Función `deposit()` — solo el buyer puede depositar ETH
- [ ] Estado del contrato con `enum State { AWAITING_DELIVERY, COMPLETE, DISPUTED, REFUNDED }`
- [ ] Función `confirmDelivery()` — buyer confirma entrega → fondos van al seller
- [ ] Función `refund()` — árbitro puede reembolsar al buyer
- [ ] Función `resolveDispute(bool releaseToSeller)` — árbitro decide ganador
- [ ] Función `openDispute()` — buyer o seller pueden abrir disputa
- [ ] Timeout automático: si pasa X días sin acción, el buyer puede reclamar reembolso
- [ ] Eventos para cada acción importante (`Deposited`, `DeliveryConfirmed`, `DisputeOpened`, `DisputeResolved`, `Refunded`)
- [ ] Fee del protocolo (ej. 1%) deducido al liberar fondos → va a una dirección `owner`

---

### Fase 2 — Tests completos

- [ ] Test: buyer deposita correctamente
- [ ] Test: no-buyer no puede depositar
- [ ] Test: buyer confirma entrega → seller recibe fondos menos fee
- [ ] Test: árbitro resuelve a favor del seller
- [ ] Test: árbitro resuelve a favor del buyer (refund)
- [ ] Test: nadie puede abrir disputa antes del depósito
- [ ] Test: timeout — buyer reclama reembolso después del plazo
- [ ] Fuzz test: `resolveDispute` con diferentes amounts
- [ ] Alcanzar **100% de coverage** con `forge coverage`

---

### Fase 3 — Scripts y deployment

- [ ] `HelperConfig.s.sol` con configuración por red (local Anvil + Sepolia)
- [ ] `DeployEscrow.s.sol` con script de deployment completo
- [ ] Deploy en **Sepolia testnet**
- [ ] Verificar contrato en Etherscan con `--verify`
- [ ] Agregar dirección del contrato verificado al README

---

### Fase 4 — CI/CD y calidad

- [ ] GitHub Actions: `forge fmt --check` + `forge build` + `forge test` en cada push
- [ ] `.env.example` con variables necesarias
- [ ] `.gitignore` correcto (no subir `.env`)
- [ ] `Makefile` con comandos: `deploy`, `test`, `coverage`, `verify`
- [ ] Gas snapshot con `forge snapshot`

---

### Fase 5 — README profesional

- [ ] Descripción clara del proyecto y por qué existe
- [ ] Diagrama del flujo (texto o imagen)
- [ ] Tech stack table
- [ ] Instrucciones de instalación y uso
- [ ] Cómo correr los tests
- [ ] Dirección deployada en Sepolia con link a Etherscan
- [ ] Sección de **Security Notes** con limitaciones conocidas
- [ ] Sección de posibles mejoras futuras

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