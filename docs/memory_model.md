# Modelo de Memória Kyn

- Alocação explícita (sem GC).
- `unsafe` obrigatório para acesso direto ao silício / ponteiros crus.
- `#[repr(C)]` para ABI C e layout previsível.
- `@align` e `@packed` para controle de layout.
- Ownership / Move para evitar aliasing mutável não controlado.
