# Plantilla piel: Clínica Dental — Motor LIA

Cómo instanciar un workspace de clínica dental en minutos a partir del template.

---

## Variables obligatorias

Abre `voice_context_kb.template.yaml` y rellena todos los campos marcados con `<< >>`:

| Variable | Dónde aparece | Ejemplo |
|---|---|---|
| `NOMBRE_CLINICA` | nombre del negocio + saludo LIA | `Clínica Dental Rigo` |
| `CALLE, Nº, CP, CIUDAD` | dirección para consultas de ubicación | `C/ Mayor 12, 28001 Madrid` |
| `TELEFONO_PRINCIPAL` | dato de contacto del negocio | `+34 910 000 000` |
| `HORARIO` | horario que LIA repite en voz/chat | `L-V 9:00-20:00, S 10:00-14:00` |
| `TRATAMIENTO_N` | lista de tratamientos disponibles | `Ortodoncia, Implantes, ...` |
| `PARKING / ACCESO` | respuesta a "¿dónde aparco?" | `Parking público a 100m` |
| `TELEFONO_URGENCIAS` | número para urgencias (o `null`) | `+34 910 000 001` |
| `CRITERIO_ESPECIFICO` | cuándo escalar a una persona | `Paciente VIP, reclamación seguros` |
| `EMAIL_DPO` | responsable de protección de datos | `dpo@clinica.es` o `null` |

El campo `treatments_list` en `assistants.metadata` debe ser la versión **inline** (separada por comas o saltos de línea) de la misma lista.

---

## Cómo aplicar al workspace

### 1. Crear el workspace en la base de datos

```sql
INSERT INTO client_workspaces (company_name, sector_code, metadata)
VALUES (
  'Clínica Dental Rigo',
  'clinica',
  '{"voice_context_kb": { /* pega el bloque voice_context_kb del YAML */ }}'
);
```

O desde el panel de administración: crear workspace → sector `clinica`.

### 2. Crear o vincular el asistente

```sql
INSERT INTO assistants (behavior_preset, metadata)
VALUES (
  'lia_demo_clinica',
  '{
    "clinic_name": "Clínica Dental Rigo",
    "clinic_hours": "L-V 9:00-20:00, S 10:00-14:00",
    "treatments_list": "ortodoncia, implantes, estética dental, blanqueamiento",
    "voice_recording_disclosure": true
  }'
);
-- Luego actualizar client_workspaces.assistant_id con el id generado
```

### 3. Asignar número Twilio (canal voz)

```sql
UPDATE client_workspaces
SET metadata = jsonb_set(
  metadata,
  '{twilio_numbers}',
  '["+34930XXXXXX"]'
)
WHERE id = '<workspace_id>';
```

### 4. Verificar el routing

El motor selecciona el preset correcto cuando:
- `assistants.behavior_preset = 'lia_demo_clinica'`
- El número entrante resuelve a este workspace

LIA se presenta como asistente virtual de `clinic_name` e incluye el aviso RGPD al inicio de cada llamada de voz.

---

## Bloque de cumplimiento (no modificar)

Los tres campos siguientes están fijados en la plantilla y **no deben cambiarse**:

| Campo | Valor | Significado |
|---|---|---|
| `compliance.agente_es_ia` | `true` | LIA se identifica siempre como IA, nunca como persona |
| `compliance.aviso_grabacion` | `true` | Aviso RGPD al inicio de cada llamada de voz |
| `compliance.rgpd.datos_ue` | `true` | Datos tratados exclusivamente en servidores de la UE |

`voice_recording_disclosure: true` en `assistants.metadata` activa la frase:
> *"Esta llamada puede grabarse y tratarse conforme al RGPD; puede oponerse en cualquier momento."*

al inicio del saludo de voz.

---

## Clientes de referencia

| Cliente | `clinic_name` | `workspace_id` |
|---|---|---|
| Rigo | `Clínica Dental Rigo` | — |
| Mateos | `Clínica Mateos` | — |
| Manuel | `Clínica Dr. Manuel` | — |

Completar `workspace_id` tras la creación en base de datos.

---

## Notas

- `tono`: usar `formal` para clínicas de implantes/estética de gama alta, `neutro` para clínicas generalistas, `cercano` para odontopediatría.
- `idiomas`: añadir `en`, `ca`, `fr` según la demografía local de la clínica. LIA detecta el idioma del interlocutor y responde en ese idioma si está en la lista.
- `treatments_list`: LIA **no inventará** tratamientos fuera de esta lista. Ser exhaustivo aquí reduce los casos en que LIA deriva al equipo humano innecesariamente.
