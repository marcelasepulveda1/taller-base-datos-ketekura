# Centro Médico Ketekura · Evaluación Parcial 2 · Taller de Base de Datos (BDY1103)

Implementación de programas PL/SQL (procedimientos, funciones y packages) sobre el modelo del **Centro Médico Ketekura**.

## Contexto del problema

El Centro Médico Ketekura registra atenciones médicas que vinculan a un paciente con un médico en una especialidad. Cada atención genera un registro de cobranza en `PAGO_ATENCION` con su fecha de vencimiento y de pago. Hoy no existe un proceso que:

- calcule automáticamente los **días de morosidad** y la **multa** de los pagos atrasados,
- aplique el **descuento para adultos mayores** definido en la tabla paramétrica `PORC_DESCTO_3RA_EDAD`,
- calcule cuánto paga cada paciente según su **convenio de salud** (Fonasa, Isapre, FF.AA., Carabineros/PDI o Particular),
- resuma mensualmente las **atenciones e incentivos de cada médico**.

Los objetos PL/SQL de este proyecto resuelven esos procesos.

## Orden de ejecución (SQL Developer, F5 "Ejecutar script")

| # | Archivo | Qué hace |
|---|---|---|
| 1 | `01 Script de Carga Ketekura.sql` | Crea y puebla las tablas del modelo (versión sin tildes del script entregado) |
| 2 | `00 Tablas nuevas Ketekura.sql` | Crea `PAGO_MOROSO`, `RESUMEN_ATENCION_MEDICO` y `ERROR_PROCESO` |
| 3 | `Requerimiento 2.sql` | Funciones almacenadas (van antes porque los procedimientos las usan) |
| 4 | `Requerimiento 1.sql` | Procedimientos almacenados |
| 5 | `Requerimiento 3.sql` | Packages |
| 6 | `Requerimiento 4.sql` | Triggers (y tabla de auditoría `LOG_KETEKURA`) |

## Tablas nuevas

| Tabla | Para qué sirve |
|---|---|
| `PAGO_MOROSO` | Detalle de cada pago atrasado: días, multa, % de descuento por edad y multa final |
| `RESUMEN_ATENCION_MEDICO` | Atenciones, total recaudado e incentivo de cada médico por mes |
| `ERROR_PROCESO` | Registro de errores: si falla un registro se anota y el proceso continúa |

## Reglas de negocio definidas por el equipo

**Multa diaria por atraso según especialidad**

| Grupo | Especialidades (esp_id) | Multa por día |
|---|---|---|
| Cirugías | 100, 1300, 1400, 1900 | $1.200 |
| Alta complejidad | 1500 Cardiología, 800 Neurología, 1700 Oncología | $1.000 |
| Intermedia | 200 Traumatología, 500 Fisiatría, 1000 Oftalmología | $900 |
| Resto | Demás especialidades | $700 |

**Descuento adulto mayor:** se aplica sobre la multa, según `PORC_DESCTO_3RA_EDAD` (65-70: 2 %, 71-75: 5 %, 76-80: 8 %, 81-85: 10 %, 86 o más: 20 %).

**Copago del paciente:** costo de la atención × `SALUD.costo_pago` / 100, menos el descuento de adulto mayor.

**Incentivo del médico:** 0-2 atenciones en el mes = 0 %; 3-5 = 5 %; 6 o más = 8 %; más 2 % si tiene 10 o más años de contrato.

## Requerimiento 1 · Procedimientos almacenados

| Procedimiento | Parámetros | Qué hace |
|---|---|---|
| `sp_calcular_morosidad` | `p_anno IN`, `p_procesados OUT`, `p_total_multas OUT` | Recorre los pagos atrasados del año, calcula días, multa y descuento, actualiza `PAGO_ATENCION` y guarda el detalle en `PAGO_MOROSO` |
| `sp_resumen_atencion_medico` | `p_mes IN`, `p_anno IN` | Resume atenciones, recaudación e incentivo de cada médico en el mes |
| `sp_proceso_mensual` | Sin parámetros | Invoca a los dos anteriores (año anterior y mes anterior) |
| `sp_listado_morosos` | Sin parámetros | Reporte de multas agrupado por especialidad |

**¿Por qué procedimientos?** Son procesos masivos que recorren muchas filas con un cursor, toman decisiones por cada una y modifican datos. No devuelven un valor para usar en un `SELECT`.

```sql
-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  REQUERIMIENTO 1: PROCEDIMIENTOS ALMACENADOS (con y sin parametros)
--
--  REQUISITO PREVIO: haber ejecutado
--    1) 01 Script de Carga Ketekura.sql
--    2) 00 Tablas nuevas Ketekura.sql
--    3) Requerimiento 2.sql   (funciones que usan estos procedimientos)
--
--  Procedimientos:
--   1.1 sp_calcular_morosidad(p_anno IN, p_procesados OUT, p_total_multas OUT)
--   1.2 sp_resumen_atencion_medico(p_mes IN, p_anno IN)
--   1.3 sp_proceso_mensual                    -> SIN parametros, invoca a 1.1 y 1.2
--   1.4 sp_listado_morosos                    -> SIN parametros, reporte
-- =====================================================================

SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------
-- 1.1 CALCULO DE MOROSIDAD  (parametros IN y OUT)
-- Recorre con un cursor explicito todos los pagos con vencimiento en el
-- anio recibido que se pagaron (o siguen sin pagar) despues de la fecha
-- de vencimiento. Para cada uno:
--   * dias de morosidad = fecha de pago (o hoy) - fecha de vencimiento
--   * multa = dias * multa diaria de la especialidad (fn_multa_diaria)
--   * si el paciente es adulto mayor se descuenta el % de la tabla
--     PORC_DESCTO_3RA_EDAD sobre la multa (fn_edad_paciente y
--     fn_porc_descto_3ra_edad)
--   * actualiza PAGO_ATENCION (dias, monto a cancelar y observacion)
--   * guarda el detalle en PAGO_MOROSO
-- Si el anio ya se proceso, borra ese anio y lo vuelve a calcular.
-- Si falla un registro, lo anota en ERROR_PROCESO y sigue con el resto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_calcular_morosidad
  (p_anno          IN  NUMBER,
   p_procesados    OUT NUMBER,
   p_total_multas  OUT NUMBER)
IS
  CURSOR c_atrasados IS
    SELECT pa.ate_id, pa.fecha_venc_pago, pa.fecha_pago, pa.monto_atencion,
           a.esp_id, e.nombre AS especialidad,
           p.pac_run, p.pnombre || ' ' || p.apaterno || ' ' || p.amaterno AS nombre_paciente
      FROM pago_atencion pa
      JOIN atencion a     ON a.ate_id  = pa.ate_id
      JOIN especialidad e ON e.esp_id  = a.esp_id
      JOIN paciente p     ON p.pac_run = a.pac_run
     WHERE EXTRACT(YEAR FROM pa.fecha_venc_pago) = p_anno
       AND NVL(pa.fecha_pago, TRUNC(SYSDATE)) > pa.fecha_venc_pago
     ORDER BY pa.ate_id;

  -- RECORD con el resultado del calculo de cada pago
  TYPE t_calculo IS RECORD
    (dias         NUMBER,
     edad         NUMBER,
     multa        NUMBER,
     porc_descto  NUMBER,
     monto_descto NUMBER,
     multa_final  NUMBER);
  r_calc  t_calculo;

  v_msg  VARCHAR2(400);
BEGIN
  p_procesados   := 0;
  p_total_multas := 0;

  IF p_anno IS NULL OR p_anno > EXTRACT(YEAR FROM SYSDATE) THEN
    RAISE_APPLICATION_ERROR(-20001, 'El anio a procesar no es valido');
  END IF;

  -- Reproceso: se borra lo calculado antes para ese anio
  DELETE FROM pago_moroso WHERE anno_proceso = p_anno;

  FOR r IN c_atrasados LOOP
    BEGIN
      SAVEPOINT sp_fila;

      r_calc.dias         := NVL(r.fecha_pago, TRUNC(SYSDATE)) - r.fecha_venc_pago;
      r_calc.edad         := fn_edad_paciente(r.pac_run);
      r_calc.multa        := r_calc.dias * fn_multa_diaria(r.esp_id);
      r_calc.porc_descto  := fn_porc_descto_3ra_edad(r_calc.edad);
      r_calc.monto_descto := ROUND(r_calc.multa * r_calc.porc_descto / 100);
      r_calc.multa_final  := r_calc.multa - r_calc.monto_descto;

      UPDATE pago_atencion
         SET dias_morosidad   = r_calc.dias,
             monto_a_cancelar = monto_atencion + r_calc.multa_final,
             obs_pago         = 'Pago atrasado ' || r_calc.dias || ' dias. Multa $' || r_calc.multa_final
       WHERE ate_id = r.ate_id;

      INSERT INTO pago_moroso
        (ate_id, anno_proceso, pac_run, nombre_paciente, edad_paciente, especialidad,
         fecha_venc_pago, fecha_pago, dias_morosidad, monto_multa, porc_descto,
         monto_descto, multa_final, fecha_proceso)
      VALUES
        (r.ate_id, p_anno, r.pac_run, SUBSTR(r.nombre_paciente, 1, 50), r_calc.edad, r.especialidad,
         r.fecha_venc_pago, r.fecha_pago, r_calc.dias, r_calc.multa, r_calc.porc_descto,
         r_calc.monto_descto, r_calc.multa_final, SYSDATE);

      p_procesados   := p_procesados + 1;
      p_total_multas := p_total_multas + r_calc.multa_final;
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO sp_fila;   -- deshace solo este registro
        v_msg := 'Atencion ' || r.ate_id || ': ' || SQLERRM;
        INSERT INTO error_proceso (id_error, nombre_proceso, descripcion, fecha_error)
        VALUES (sq_error.NEXTVAL, 'SP_CALCULAR_MOROSIDAD', SUBSTR(v_msg, 1, 400), SYSDATE);
    END;
  END LOOP;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_calcular_morosidad;
/

-- ---------------------------------------------------------------------
-- 1.2 RESUMEN MENSUAL DE ATENCIONES POR MEDICO  (parametros IN)
-- Para CADA medico cuenta sus atenciones del mes, suma lo recaudado
-- (costo de las atenciones), aplica el % de incentivo de
-- fn_porc_incentivo (2.5) y guarda el resultado en
-- RESUMEN_ATENCION_MEDICO. Si el periodo ya existe, lo recalcula.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_resumen_atencion_medico
  (p_mes   IN NUMBER,
   p_anno  IN NUMBER)
IS
  CURSOR c_medicos IS
    SELECT med_run
      FROM medico
     ORDER BY med_run;

  v_fec_desde   DATE;
  v_fec_hasta   DATE;
  v_cant        NUMBER;
  v_total       NUMBER;
  v_porc        NUMBER;
  v_procesados  NUMBER := 0;
BEGIN
  IF p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 THEN
    RAISE_APPLICATION_ERROR(-20002, 'El mes debe estar entre 1 y 12');
  END IF;

  v_fec_desde := TO_DATE('01/' || LPAD(p_mes, 2, '0') || '/' || p_anno, 'DD/MM/YYYY');
  v_fec_hasta := ADD_MONTHS(v_fec_desde, 1);

  DELETE FROM resumen_atencion_medico
   WHERE anno = p_anno
     AND mes  = p_mes;

  FOR m IN c_medicos LOOP
    SELECT COUNT(*), NVL(SUM(costo), 0)
      INTO v_cant, v_total
      FROM atencion
     WHERE med_run = m.med_run
       AND fecha_atencion >= v_fec_desde
       AND fecha_atencion <  v_fec_hasta;

    v_porc := fn_porc_incentivo(m.med_run, v_cant);

    INSERT INTO resumen_atencion_medico
      (med_run, anno, mes, cant_atenciones, total_recaudado,
       porc_incentivo, monto_incentivo, fecha_proceso)
    VALUES
      (m.med_run, p_anno, p_mes, v_cant, v_total,
       v_porc, ROUND(v_total * v_porc / 100), SYSDATE);

    v_procesados := v_procesados + 1;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Resumen ' || LPAD(p_mes, 2, '0') || '/' || p_anno
                       || ': ' || v_procesados || ' medicos procesados');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_resumen_atencion_medico;
/

-- ---------------------------------------------------------------------
-- 1.3 PROCESO MENSUAL  (SIN parametros)
-- Invoca a otros procedimientos: calcula la morosidad del anio anterior
-- y el resumen de medicos del mes anterior. Es lo que el centro medico
-- ejecutaria a principio de cada mes con una sola llamada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_proceso_mensual
IS
  v_procesados  NUMBER;
  v_multas      NUMBER;
  v_mes_ant     DATE := ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -1);
BEGIN
  sp_calcular_morosidad(EXTRACT(YEAR FROM SYSDATE) - 1, v_procesados, v_multas);
  DBMS_OUTPUT.PUT_LINE('Morosidad anio anterior: ' || v_procesados
                       || ' pagos atrasados, multas $' || v_multas);

  sp_resumen_atencion_medico(EXTRACT(MONTH FROM v_mes_ant), EXTRACT(YEAR FROM v_mes_ant));
END sp_proceso_mensual;
/

-- ---------------------------------------------------------------------
-- 1.4 LISTADO DE MOROSOS  (SIN parametros)
-- Reporte por especialidad de los pagos atrasados ya calculados en
-- PAGO_MOROSO, con el total de multas de cada especialidad.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_listado_morosos
IS
  CURSOR c_resumen IS
    SELECT especialidad, COUNT(*) AS cantidad, SUM(dias_morosidad) AS dias,
           SUM(multa_final) AS total_multa
      FROM pago_moroso
     GROUP BY especialidad
     ORDER BY total_multa DESC;

  v_total  NUMBER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== PAGOS ATRASADOS POR ESPECIALIDAD ===');
  FOR r IN c_resumen LOOP
    DBMS_OUTPUT.PUT_LINE(RPAD(r.especialidad, 30) || LPAD(r.cantidad, 5) || ' pagos'
                         || LPAD(r.dias, 7) || ' dias   multa $'
                         || TO_CHAR(r.total_multa, 'FM999G999G990'));
    v_total := v_total + r.total_multa;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Total multas: $' || TO_CHAR(v_total, 'FM999G999G990'));
  DBMS_OUTPUT.PUT_LINE('Pagos atrasados en toda la base: ' || fn_total_pagos_atrasados);
END sp_listado_morosos;
/


-- =====================================================================
--  PRUEBAS DEL REQUERIMIENTO 1
-- =====================================================================

-- Prueba 1: morosidad del anio anterior invocada desde un bloque anonimo
-- (parametro IN = anio, parametros OUT = cantidad y total de multas)
DECLARE
  v_procesados  NUMBER;
  v_multas      NUMBER;
BEGIN
  sp_calcular_morosidad(EXTRACT(YEAR FROM SYSDATE) - 1, v_procesados, v_multas);
  DBMS_OUTPUT.PUT_LINE('Pagos atrasados procesados: ' || v_procesados);
  DBMS_OUTPUT.PUT_LINE('Total multas             : $' || v_multas);
END;
/

-- Lo que quedo en PAGO_MOROSO (los adultos mayores tienen descuento)
SELECT ate_id, nombre_paciente, edad_paciente, especialidad, dias_morosidad,
       monto_multa, porc_descto, monto_descto, multa_final
  FROM pago_moroso
 ORDER BY multa_final DESC;

-- Como quedo PAGO_ATENCION para esos pagos
SELECT ate_id, fecha_venc_pago, fecha_pago, monto_atencion, dias_morosidad,
       monto_a_cancelar, obs_pago
  FROM pago_atencion
 WHERE dias_morosidad IS NOT NULL
 ORDER BY dias_morosidad DESC;

-- Prueba 2: reprocesar el mismo anio NO duplica (la cantidad se mantiene)
DECLARE
  v_procesados  NUMBER;
  v_multas      NUMBER;
BEGIN
  sp_calcular_morosidad(EXTRACT(YEAR FROM SYSDATE) - 1, v_procesados, v_multas);
END;
/
SELECT COUNT(*) AS filas_pago_moroso FROM pago_moroso;

-- Prueba 3: resumen de medicos de AGOSTO del anio actual
EXEC sp_resumen_atencion_medico(8, EXTRACT(YEAR FROM SYSDATE));

SELECT r.med_run,
       m.pnombre || ' ' || m.apaterno AS medico,
       r.cant_atenciones, r.total_recaudado, r.porc_incentivo, r.monto_incentivo
  FROM resumen_atencion_medico r
  JOIN medico m ON m.med_run = r.med_run
 WHERE r.anno = EXTRACT(YEAR FROM SYSDATE)
   AND r.mes  = 8
 ORDER BY r.monto_incentivo DESC, r.cant_atenciones DESC;

-- Prueba 4: procedimiento SIN parametros que invoca a otros dos
EXEC sp_proceso_mensual;

-- Prueba 5: reporte SIN parametros
EXEC sp_listado_morosos;

-- Errores registrados (lo esperado es que no haya ninguno)
SELECT * FROM error_proceso ORDER BY id_error;

-- Prueba 6: error controlado -> anio invalido (debe mostrar ORA-20001)
DECLARE
  v_p NUMBER;
  v_m NUMBER;
BEGIN
  sp_calcular_morosidad(3000, v_p, v_m);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error controlado: ' || SQLERRM);
END;
/
```

## Requerimiento 2 · Funciones almacenadas

| Función | Parámetros | Retorna | Si el dato no existe |
|---|---|---|---|
| `fn_edad_paciente` | `p_pac_run` | Edad en años | -1 |
| `fn_porc_descto_3ra_edad` | `p_edad` | % de descuento | 0 |
| `fn_multa_diaria` | `p_esp_id` | Multa por día | (siempre retorna un valor) |
| `fn_copago_paciente` | `p_ate_id` | Monto que paga el paciente | -1 |
| `fn_porc_incentivo` | `p_med_run`, `p_cant_atenciones` | % de incentivo | 0 |
| `fn_total_pagos_atrasados` | Sin parámetros | Cantidad de pagos atrasados | (COUNT siempre retorna) |

**¿Por qué funciones?** Son cálculos que devuelven un valor y se repiten en muchos lugares: dentro de `SELECT`, en los procedimientos y en los packages. Así la regla queda escrita una sola vez.

```sql
-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  REQUERIMIENTO 2: FUNCIONES ALMACENADAS (con y sin parametros)
--
--  ORDEN DE EJECUCION: este archivo va ANTES que el Requerimiento 1,
--  porque los procedimientos del Req. 1 usan estas funciones.
--
--  Funciones:
--   2.1 fn_edad_paciente(p_pac_run)            -> con parametro
--   2.2 fn_porc_descto_3ra_edad(p_edad)        -> con parametro
--   2.3 fn_multa_diaria(p_esp_id)              -> con parametro
--   2.4 fn_copago_paciente(p_ate_id)           -> con parametro
--   2.5 fn_porc_incentivo(p_med_run, p_cant)   -> con parametros
--   2.6 fn_total_pagos_atrasados               -> SIN parametros
-- =====================================================================

SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------
-- 2.1 EDAD DEL PACIENTE
-- Retorna la edad en anios cumplidos a la fecha actual.
-- Si el paciente no existe retorna -1 (controlado con NO_DATA_FOUND).
-- Se reutiliza en: fn_copago_paciente, sp_calcular_morosidad y packages.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_edad_paciente
  (p_pac_run IN NUMBER)
RETURN NUMBER
IS
  v_fec_nac  paciente.fecha_nacimiento%TYPE;
BEGIN
  SELECT fecha_nacimiento
    INTO v_fec_nac
    FROM paciente
   WHERE pac_run = p_pac_run;

  RETURN TRUNC(MONTHS_BETWEEN(SYSDATE, v_fec_nac) / 12);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN -1;   -- valor documentado: "el paciente no existe"
END fn_edad_paciente;
/

-- ---------------------------------------------------------------------
-- 2.2 PORCENTAJE DE DESCUENTO POR TERCERA EDAD
-- Busca la edad en la tabla parametrica PORC_DESCTO_3RA_EDAD
-- (65-70: 2%, 71-75: 5%, 76-80: 8%, 81-85: 10%, 86 o mas: 20%).
-- Si la edad no esta en ningun tramo (menor de 65) retorna 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_porc_descto_3ra_edad
  (p_edad IN NUMBER)
RETURN NUMBER
IS
  v_porc  porc_descto_3ra_edad.porcentaje_descto%TYPE;
BEGIN
  SELECT porcentaje_descto
    INTO v_porc
    FROM porc_descto_3ra_edad
   WHERE p_edad BETWEEN anno_ini AND anno_ter;

  RETURN v_porc;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;   -- no es adulto mayor: sin descuento
END fn_porc_descto_3ra_edad;
/

-- ---------------------------------------------------------------------
-- 2.3 MULTA DIARIA POR ATRASO SEGUN ESPECIALIDAD
-- Regla definida por el equipo (pesos por cada dia de atraso):
--   Cirugias (100, 1300, 1400, 1900)                  -> $1.200
--   Cardiologia, Neurologia, Oncologia (1500, 800, 1700) -> $1.000
--   Traumatologia, Fisiatria, Oftalmologia (200, 500, 1000) -> $900
--   Resto de especialidades                           -> $700
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_multa_diaria
  (p_esp_id IN NUMBER)
RETURN NUMBER
IS
BEGIN
  RETURN CASE
           WHEN p_esp_id IN (100, 1300, 1400, 1900) THEN 1200
           WHEN p_esp_id IN (1500, 800, 1700)       THEN 1000
           WHEN p_esp_id IN (200, 500, 1000)        THEN 900
           ELSE 700
         END;
END fn_multa_diaria;
/

-- ---------------------------------------------------------------------
-- 2.4 COPAGO DEL PACIENTE PARA UNA ATENCION
-- SALUD.costo_pago es el % del costo que paga el paciente segun su
-- convenio (Fonasa A = 0%, Particular = 100%, etc.).
-- Si el paciente es adulto mayor se aplica ademas el descuento por edad.
-- Usa: fn_edad_paciente (2.1) y fn_porc_descto_3ra_edad (2.2).
-- Si la atencion no existe retorna -1.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_copago_paciente
  (p_ate_id IN NUMBER)
RETURN NUMBER
IS
  v_costo     atencion.costo%TYPE;
  v_pac_run   atencion.pac_run%TYPE;
  v_porc_pago salud.costo_pago%TYPE;
  v_copago    NUMBER;
  v_descto    NUMBER;
BEGIN
  SELECT a.costo, a.pac_run, NVL(s.costo_pago, 100)
    INTO v_costo, v_pac_run, v_porc_pago
    FROM atencion a
    JOIN paciente p ON p.pac_run = a.pac_run
    LEFT JOIN salud s ON s.sal_id = p.sal_id
   WHERE a.ate_id = p_ate_id;

  v_copago := v_costo * v_porc_pago / 100;
  v_descto := v_copago * fn_porc_descto_3ra_edad(fn_edad_paciente(v_pac_run)) / 100;

  RETURN ROUND(v_copago - v_descto);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN -1;   -- la atencion no existe
END fn_copago_paciente;
/

-- ---------------------------------------------------------------------
-- 2.5 PORCENTAJE DE INCENTIVO DEL MEDICO
-- Regla definida por el equipo:
--   segun cantidad de atenciones del mes:
--     0 a 2 = 0%    3 a 5 = 5%    6 o mas = 8%
--   + 2% adicional si tiene 10 o mas anios de contrato.
-- Si el medico no existe retorna 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_porc_incentivo
  (p_med_run       IN NUMBER,
   p_cant_atenciones IN NUMBER)
RETURN NUMBER
IS
  v_fec_contrato  medico.fecha_contrato%TYPE;
  v_porc          NUMBER := 0;
BEGIN
  SELECT fecha_contrato
    INTO v_fec_contrato
    FROM medico
   WHERE med_run = p_med_run;

  IF p_cant_atenciones >= 6 THEN
    v_porc := 8;
  ELSIF p_cant_atenciones >= 3 THEN
    v_porc := 5;
  ELSE
    v_porc := 0;
  END IF;

  IF v_porc > 0 AND MONTHS_BETWEEN(SYSDATE, v_fec_contrato) / 12 >= 10 THEN
    v_porc := v_porc + 2;
  END IF;

  RETURN v_porc;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;
END fn_porc_incentivo;
/

-- ---------------------------------------------------------------------
-- 2.6 CANTIDAD DE PAGOS ATRASADOS (funcion SIN parametros)
-- Un pago esta atrasado si se pago despues de su fecha de vencimiento,
-- o si no se ha pagado y la fecha de vencimiento ya paso.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_pagos_atrasados
RETURN NUMBER
IS
  v_cantidad NUMBER := 0;
BEGIN
  SELECT COUNT(*)
    INTO v_cantidad
    FROM pago_atencion
   WHERE NVL(fecha_pago, TRUNC(SYSDATE)) > fecha_venc_pago;
  RETURN v_cantidad;
END fn_total_pagos_atrasados;
/


-- =====================================================================
--  PRUEBAS DEL REQUERIMIENTO 2
-- =====================================================================

-- Prueba 1: edad y descuento de todos los pacientes adultos mayores
-- (funciones dentro del SELECT, del WHERE y del ORDER BY)
SELECT p.pac_run,
       p.pnombre || ' ' || p.apaterno                       AS paciente,
       fn_edad_paciente(p.pac_run)                          AS edad,
       fn_porc_descto_3ra_edad(fn_edad_paciente(p.pac_run)) AS porc_descto
  FROM paciente p
 WHERE fn_edad_paciente(p.pac_run) >= 65
 ORDER BY edad DESC;

-- Prueba 2: copago de cada atencion del anio actual, junto a su costo
SELECT a.ate_id,
       a.fecha_atencion,
       a.costo,
       s.descripcion                  AS convenio,
       s.costo_pago                   AS porc_paga_paciente,
       fn_copago_paciente(a.ate_id)   AS copago
  FROM atencion a
  JOIN paciente p ON p.pac_run = a.pac_run
  JOIN salud s    ON s.sal_id  = p.sal_id
 WHERE EXTRACT(YEAR FROM a.fecha_atencion) = EXTRACT(YEAR FROM SYSDATE)
 ORDER BY copago DESC;

-- Prueba 3: multa diaria de cada especialidad
SELECT esp_id, nombre, fn_multa_diaria(esp_id) AS multa_diaria
  FROM especialidad
 ORDER BY multa_diaria DESC, esp_id;

-- Prueba 4: incentivo de cada medico segun sus atenciones de agosto del anio actual
SELECT m.med_run,
       m.pnombre || ' ' || m.apaterno                     AS medico,
       COUNT(a.ate_id)                                    AS atenciones,
       fn_porc_incentivo(m.med_run, COUNT(a.ate_id))      AS porc_incentivo
  FROM medico m
  LEFT JOIN atencion a
         ON a.med_run = m.med_run
        AND EXTRACT(MONTH FROM a.fecha_atencion) = 8
        AND EXTRACT(YEAR  FROM a.fecha_atencion) = EXTRACT(YEAR FROM SYSDATE)
 GROUP BY m.med_run, m.pnombre, m.apaterno
 ORDER BY atenciones DESC;

-- Prueba 5: casos controlados
SELECT fn_edad_paciente(1)        AS paciente_inexistente,
       fn_copago_paciente(99999)  AS atencion_inexistente,
       fn_porc_descto_3ra_edad(40) AS descto_40_anios
  FROM dual;

-- Prueba 6: funcion SIN parametros dentro de un SELECT
SELECT fn_total_pagos_atrasados AS pagos_atrasados FROM dual;

-- Prueba 7: funciones invocadas desde otro programa PL/SQL (bloque anonimo)
DECLARE
  v_edad  NUMBER;
BEGIN
  v_edad := fn_edad_paciente(6626326);
  DBMS_OUTPUT.PUT_LINE('Edad paciente 6626326: ' || v_edad || ' anios');
  DBMS_OUTPUT.PUT_LINE('Descuento 3ra edad   : ' || fn_porc_descto_3ra_edad(v_edad) || '%');
  DBMS_OUTPUT.PUT_LINE('Multa diaria esp. 100: $' || fn_multa_diaria(100));
  DBMS_OUTPUT.PUT_LINE('Pagos atrasados      : ' || fn_total_pagos_atrasados);
END;
/
```

## Requerimiento 3 · Packages

| Package | Público (especificación) | Privado (solo cuerpo) |
|---|---|---|
| `pkg_cobranza` | `c_edad_adulto_mayor`, `g_ultimos_procesados`, `fn_edad_paciente`, `fn_copago_paciente`, `fn_total_pagos_atrasados`, `sp_calcular_morosidad` | `c_max_dias_multa`, VARRAY de multas, `fn_multa_diaria`, `fn_porc_descto`, `sp_registra_error` |
| `pkg_gestion_medica` | `g_medicos_procesados`, `fn_porc_incentivo`, `fn_incentivo_medico`, `sp_resumen_mensual` | `c_anios_bono`, `c_porc_bono`, `fn_anios_contrato`, `fn_porc_por_cantidad`, `sp_registra_error` |

**¿Qué se dejó público y qué privado?** Es público lo que necesitan otras áreas o aplicaciones (calcular la morosidad, consultar el copago o el incentivo). Es privado lo que son reglas internas del cálculo (tramos de multa, tramos de incentivo, registro de errores), para poder cambiarlas en el cuerpo sin afectar a quien usa el package.

```sql
-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  REQUERIMIENTO 3: PACKAGES con constructores PUBLICOS y PRIVADOS
--
--  REQUISITO PREVIO: Script de Carga + Tablas nuevas + Req. 2 + Req. 1
--
--  3.1 PKG_COBRANZA       : agrupa edad del paciente (2.1), descuento 3ra
--                           edad (2.2), multa diaria (2.3), copago (2.4),
--                           pagos atrasados (2.6) y el calculo de
--                           morosidad (1.1).
--  3.2 PKG_GESTION_MEDICA : agrupa el % de incentivo (2.5) y el resumen
--                           mensual de atenciones por medico (1.2).
--
--  PUBLICO  = lo declarado en la ESPECIFICACION (PACKAGE). Se puede usar
--             desde otros programas, triggers y SELECT: paquete.elemento
--  PRIVADO  = lo que existe SOLO en el CUERPO (PACKAGE BODY).
-- =====================================================================

SET SERVEROUTPUT ON;

-- =====================================================================
-- 3.1 PKG_COBRANZA - ESPECIFICACION (parte publica)
-- =====================================================================
CREATE OR REPLACE PACKAGE pkg_cobranza
IS
  -- Constante publica: edad desde la que se considera adulto mayor
  c_edad_adulto_mayor  CONSTANT NUMBER := 65;

  -- Variable publica: resultado de la ultima ejecucion (dura la sesion)
  g_ultimos_procesados NUMBER := 0;

  FUNCTION fn_edad_paciente (p_pac_run IN NUMBER) RETURN NUMBER;
  FUNCTION fn_copago_paciente (p_ate_id IN NUMBER) RETURN NUMBER;
  FUNCTION fn_total_pagos_atrasados RETURN NUMBER;

  PROCEDURE sp_calcular_morosidad (p_anno          IN  NUMBER,
                                   p_procesados    OUT NUMBER,
                                   p_total_multas  OUT NUMBER);
END pkg_cobranza;
/

-- =====================================================================
-- 3.1 PKG_COBRANZA - CUERPO
-- =====================================================================
CREATE OR REPLACE PACKAGE BODY pkg_cobranza
IS
  -- ---------------- ELEMENTOS PRIVADOS ----------------

  -- Constante privada: tope de dias de atraso que se cobran como multa
  c_max_dias_multa  CONSTANT NUMBER := 365;

  -- VARRAY privado con las multas diarias por grupo de especialidad
  -- posicion 1 = cirugias, 2 = alta complejidad, 3 = intermedia, 4 = resto
  TYPE t_multas IS VARRAY(4) OF NUMBER;
  v_multas  t_multas := t_multas(1200, 1000, 900, 700);

  -- PRIVADA: multa diaria segun especialidad (usa el VARRAY)
  FUNCTION fn_multa_diaria (p_esp_id IN NUMBER) RETURN NUMBER
  IS
  BEGIN
    IF p_esp_id IN (100, 1300, 1400, 1900) THEN
      RETURN v_multas(1);
    ELSIF p_esp_id IN (1500, 800, 1700) THEN
      RETURN v_multas(2);
    ELSIF p_esp_id IN (200, 500, 1000) THEN
      RETURN v_multas(3);
    ELSE
      RETURN v_multas(4);
    END IF;
  END fn_multa_diaria;

  -- PRIVADA: % de descuento por tercera edad (tabla parametrica)
  FUNCTION fn_porc_descto (p_edad IN NUMBER) RETURN NUMBER
  IS
    v_porc NUMBER;
  BEGIN
    IF p_edad < c_edad_adulto_mayor THEN
      RETURN 0;
    END IF;
    SELECT porcentaje_descto
      INTO v_porc
      FROM porc_descto_3ra_edad
     WHERE p_edad BETWEEN anno_ini AND anno_ter;
    RETURN v_porc;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END fn_porc_descto;

  -- PRIVADO: registra un error del proceso
  PROCEDURE sp_registra_error (p_mensaje IN VARCHAR2)
  IS
  BEGIN
    INSERT INTO error_proceso (id_error, nombre_proceso, descripcion, fecha_error)
    VALUES (sq_error.NEXTVAL, 'PKG_COBRANZA.SP_CALCULAR_MOROSIDAD',
            SUBSTR(p_mensaje, 1, 400), SYSDATE);
  END sp_registra_error;

  -- ---------------- ELEMENTOS PUBLICOS ----------------

  FUNCTION fn_edad_paciente (p_pac_run IN NUMBER) RETURN NUMBER
  IS
    v_fec_nac  paciente.fecha_nacimiento%TYPE;
  BEGIN
    SELECT fecha_nacimiento INTO v_fec_nac
      FROM paciente
     WHERE pac_run = p_pac_run;
    RETURN TRUNC(MONTHS_BETWEEN(SYSDATE, v_fec_nac) / 12);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN -1;
  END fn_edad_paciente;

  FUNCTION fn_copago_paciente (p_ate_id IN NUMBER) RETURN NUMBER
  IS
    v_costo     atencion.costo%TYPE;
    v_pac_run   atencion.pac_run%TYPE;
    v_porc_pago salud.costo_pago%TYPE;
    v_copago    NUMBER;
  BEGIN
    SELECT a.costo, a.pac_run, NVL(s.costo_pago, 100)
      INTO v_costo, v_pac_run, v_porc_pago
      FROM atencion a
      JOIN paciente p ON p.pac_run = a.pac_run
      LEFT JOIN salud s ON s.sal_id = p.sal_id
     WHERE a.ate_id = p_ate_id;

    v_copago := v_costo * v_porc_pago / 100;
    -- Usa la funcion privada fn_porc_descto
    RETURN ROUND(v_copago - v_copago * fn_porc_descto(fn_edad_paciente(v_pac_run)) / 100);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN -1;
  END fn_copago_paciente;

  FUNCTION fn_total_pagos_atrasados RETURN NUMBER
  IS
    v_cantidad NUMBER := 0;
  BEGIN
    SELECT COUNT(*) INTO v_cantidad
      FROM pago_atencion
     WHERE NVL(fecha_pago, TRUNC(SYSDATE)) > fecha_venc_pago;
    RETURN v_cantidad;
  END fn_total_pagos_atrasados;

  PROCEDURE sp_calcular_morosidad (p_anno          IN  NUMBER,
                                   p_procesados    OUT NUMBER,
                                   p_total_multas  OUT NUMBER)
  IS
    CURSOR c_atrasados IS
      SELECT pa.ate_id, pa.fecha_venc_pago, pa.fecha_pago,
             a.esp_id, e.nombre AS especialidad,
             p.pac_run, p.pnombre || ' ' || p.apaterno || ' ' || p.amaterno AS nombre_paciente
        FROM pago_atencion pa
        JOIN atencion a     ON a.ate_id  = pa.ate_id
        JOIN especialidad e ON e.esp_id  = a.esp_id
        JOIN paciente p     ON p.pac_run = a.pac_run
       WHERE EXTRACT(YEAR FROM pa.fecha_venc_pago) = p_anno
         AND NVL(pa.fecha_pago, TRUNC(SYSDATE)) > pa.fecha_venc_pago
       ORDER BY pa.ate_id;

    v_dias    NUMBER;
    v_edad    NUMBER;
    v_multa   NUMBER;
    v_porc    NUMBER;
    v_descto  NUMBER;
  BEGIN
    p_procesados   := 0;
    p_total_multas := 0;

    IF p_anno IS NULL OR p_anno > EXTRACT(YEAR FROM SYSDATE) THEN
      RAISE_APPLICATION_ERROR(-20001, 'El anio a procesar no es valido');
    END IF;

    DELETE FROM pago_moroso WHERE anno_proceso = p_anno;

    FOR r IN c_atrasados LOOP
      BEGIN
        SAVEPOINT sp_fila;

        -- La constante privada limita los dias que se cobran
        v_dias   := LEAST(NVL(r.fecha_pago, TRUNC(SYSDATE)) - r.fecha_venc_pago, c_max_dias_multa);
        v_edad   := fn_edad_paciente(r.pac_run);
        v_multa  := v_dias * fn_multa_diaria(r.esp_id);      -- privada
        v_porc   := fn_porc_descto(v_edad);                  -- privada
        v_descto := ROUND(v_multa * v_porc / 100);

        UPDATE pago_atencion
           SET dias_morosidad   = v_dias,
               monto_a_cancelar = monto_atencion + (v_multa - v_descto),
               obs_pago         = 'Pago atrasado ' || v_dias || ' dias. Multa $' || (v_multa - v_descto)
         WHERE ate_id = r.ate_id;

        INSERT INTO pago_moroso
          (ate_id, anno_proceso, pac_run, nombre_paciente, edad_paciente, especialidad,
           fecha_venc_pago, fecha_pago, dias_morosidad, monto_multa, porc_descto,
           monto_descto, multa_final, fecha_proceso)
        VALUES
          (r.ate_id, p_anno, r.pac_run, SUBSTR(r.nombre_paciente, 1, 50), v_edad, r.especialidad,
           r.fecha_venc_pago, r.fecha_pago, v_dias, v_multa, v_porc,
           v_descto, v_multa - v_descto, SYSDATE);

        p_procesados   := p_procesados + 1;
        p_total_multas := p_total_multas + (v_multa - v_descto);
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK TO sp_fila;
          sp_registra_error('Atencion ' || r.ate_id || ': ' || SQLERRM);   -- privado
      END;
    END LOOP;

    g_ultimos_procesados := p_procesados;
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_calcular_morosidad;

END pkg_cobranza;
/


-- =====================================================================
-- 3.2 PKG_GESTION_MEDICA - ESPECIFICACION (parte publica)
-- =====================================================================
CREATE OR REPLACE PACKAGE pkg_gestion_medica
IS
  -- Variable publica: medicos procesados en la ultima ejecucion
  g_medicos_procesados  NUMBER := 0;

  FUNCTION fn_porc_incentivo (p_med_run IN NUMBER, p_cant_atenciones IN NUMBER) RETURN NUMBER;

  FUNCTION fn_incentivo_medico (p_med_run IN NUMBER,
                                p_mes     IN NUMBER,
                                p_anno    IN NUMBER) RETURN NUMBER;

  PROCEDURE sp_resumen_mensual (p_mes IN NUMBER, p_anno IN NUMBER);
END pkg_gestion_medica;
/

-- =====================================================================
-- 3.2 PKG_GESTION_MEDICA - CUERPO
-- =====================================================================
CREATE OR REPLACE PACKAGE BODY pkg_gestion_medica
IS
  -- ---------------- ELEMENTOS PRIVADOS ----------------
  -- Los tramos son reglas internas: quien usa el package no los conoce.

  c_anios_bono       CONSTANT NUMBER := 10;   -- anios de contrato para el bono
  c_porc_bono        CONSTANT NUMBER := 2;    -- % adicional por antiguedad

  -- PRIVADA: anios completos de contrato
  FUNCTION fn_anios_contrato (p_fecha IN DATE) RETURN NUMBER
  IS
  BEGIN
    RETURN TRUNC(MONTHS_BETWEEN(SYSDATE, p_fecha) / 12);
  END fn_anios_contrato;

  -- PRIVADA: % segun cantidad de atenciones
  FUNCTION fn_porc_por_cantidad (p_cant IN NUMBER) RETURN NUMBER
  IS
  BEGIN
    IF p_cant >= 6 THEN
      RETURN 8;
    ELSIF p_cant >= 3 THEN
      RETURN 5;
    ELSE
      RETURN 0;
    END IF;
  END fn_porc_por_cantidad;

  -- PRIVADO: registro de errores
  PROCEDURE sp_registra_error (p_mensaje IN VARCHAR2)
  IS
  BEGIN
    INSERT INTO error_proceso (id_error, nombre_proceso, descripcion, fecha_error)
    VALUES (sq_error.NEXTVAL, 'PKG_GESTION_MEDICA.SP_RESUMEN_MENSUAL',
            SUBSTR(p_mensaje, 1, 400), SYSDATE);
  END sp_registra_error;

  -- ---------------- ELEMENTOS PUBLICOS ----------------

  FUNCTION fn_porc_incentivo (p_med_run IN NUMBER, p_cant_atenciones IN NUMBER) RETURN NUMBER
  IS
    v_fec_contrato  medico.fecha_contrato%TYPE;
    v_porc          NUMBER;
  BEGIN
    SELECT fecha_contrato INTO v_fec_contrato
      FROM medico
     WHERE med_run = p_med_run;

    v_porc := fn_porc_por_cantidad(p_cant_atenciones);
    IF v_porc > 0 AND fn_anios_contrato(v_fec_contrato) >= c_anios_bono THEN
      v_porc := v_porc + c_porc_bono;
    END IF;
    RETURN v_porc;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END fn_porc_incentivo;

  FUNCTION fn_incentivo_medico (p_med_run IN NUMBER,
                                p_mes     IN NUMBER,
                                p_anno    IN NUMBER) RETURN NUMBER
  IS
    v_monto NUMBER;
  BEGIN
    SELECT monto_incentivo INTO v_monto
      FROM resumen_atencion_medico
     WHERE med_run = p_med_run
       AND mes  = p_mes
       AND anno = p_anno;
    RETURN v_monto;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;   -- periodo no procesado
  END fn_incentivo_medico;

  PROCEDURE sp_resumen_mensual (p_mes IN NUMBER, p_anno IN NUMBER)
  IS
    CURSOR c_medicos IS
      SELECT med_run FROM medico ORDER BY med_run;

    v_fec_desde  DATE;
    v_fec_hasta  DATE;
    v_cant       NUMBER;
    v_total      NUMBER;
    v_porc       NUMBER;
  BEGIN
    IF p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 THEN
      RAISE_APPLICATION_ERROR(-20002, 'El mes debe estar entre 1 y 12');
    END IF;

    g_medicos_procesados := 0;
    v_fec_desde := TO_DATE('01/' || LPAD(p_mes, 2, '0') || '/' || p_anno, 'DD/MM/YYYY');
    v_fec_hasta := ADD_MONTHS(v_fec_desde, 1);

    DELETE FROM resumen_atencion_medico WHERE anno = p_anno AND mes = p_mes;

    FOR m IN c_medicos LOOP
      BEGIN
        SELECT COUNT(*), NVL(SUM(costo), 0)
          INTO v_cant, v_total
          FROM atencion
         WHERE med_run = m.med_run
           AND fecha_atencion >= v_fec_desde
           AND fecha_atencion <  v_fec_hasta;

        v_porc := fn_porc_incentivo(m.med_run, v_cant);

        INSERT INTO resumen_atencion_medico
          (med_run, anno, mes, cant_atenciones, total_recaudado,
           porc_incentivo, monto_incentivo, fecha_proceso)
        VALUES
          (m.med_run, p_anno, p_mes, v_cant, v_total,
           v_porc, ROUND(v_total * v_porc / 100), SYSDATE);

        g_medicos_procesados := g_medicos_procesados + 1;
      EXCEPTION
        WHEN OTHERS THEN
          sp_registra_error('Medico ' || m.med_run || ': ' || SQLERRM);   -- privado
      END;
    END LOOP;

    COMMIT;
  END sp_resumen_mensual;

END pkg_gestion_medica;
/


-- =====================================================================
--  PRUEBAS DEL REQUERIMIENTO 3
-- =====================================================================

-- Prueba 0: los packages quedaron compilados sin errores (STATUS = VALID)
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('PKG_COBRANZA', 'PKG_GESTION_MEDICA')
 ORDER BY object_name, object_type;

-- Prueba 1: funciones PUBLICAS del package dentro de un SELECT
SELECT a.ate_id,
       p.pnombre || ' ' || p.apaterno               AS paciente,
       pkg_cobranza.fn_edad_paciente(a.pac_run)     AS edad,
       a.costo,
       pkg_cobranza.fn_copago_paciente(a.ate_id)    AS copago
  FROM atencion a
  JOIN paciente p ON p.pac_run = a.pac_run
 -- Nota: una CONSTANTE de un package no se puede usar dentro de un SELECT
 -- (Oracle responde PLS-221). Solo se usa en codigo PL/SQL, como en la Prueba 2.
 WHERE pkg_cobranza.fn_edad_paciente(a.pac_run) >= 65
 ORDER BY edad DESC;

-- Prueba 2: bloque anonimo que usa el procedimiento, la constante y la variable publica
DECLARE
  v_procesados  NUMBER;
  v_multas      NUMBER;
BEGIN
  pkg_cobranza.sp_calcular_morosidad(EXTRACT(YEAR FROM SYSDATE) - 2, v_procesados, v_multas);
  DBMS_OUTPUT.PUT_LINE('Adulto mayor desde       : ' || pkg_cobranza.c_edad_adulto_mayor || ' anios');
  DBMS_OUTPUT.PUT_LINE('Morosidad hace 2 anios   : ' || v_procesados || ' pagos, multas $' || v_multas);
  DBMS_OUTPUT.PUT_LINE('Variable del package     : ' || pkg_cobranza.g_ultimos_procesados);
  DBMS_OUTPUT.PUT_LINE('Pagos atrasados en la BD : ' || pkg_cobranza.fn_total_pagos_atrasados);
END;
/

-- Prueba 3: error controlado desde el package
DECLARE
  v_p NUMBER;
  v_m NUMBER;
BEGIN
  pkg_cobranza.sp_calcular_morosidad(3000, v_p, v_m);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error controlado: ' || SQLERRM);
END;
/

-- Prueba 4: package de gestion medica. Procesa JULIO del anio actual
BEGIN
  pkg_gestion_medica.sp_resumen_mensual(7, EXTRACT(YEAR FROM SYSDATE));
  DBMS_OUTPUT.PUT_LINE('Medicos procesados: ' || pkg_gestion_medica.g_medicos_procesados);
END;
/

-- Prueba 5: funciones publicas de gestion medica en un SELECT de todos los medicos
SELECT m.med_run,
       m.pnombre || ' ' || m.apaterno AS medico,
       pkg_gestion_medica.fn_incentivo_medico(m.med_run, 7, EXTRACT(YEAR FROM SYSDATE)) AS incentivo_julio
  FROM medico m
 ORDER BY incentivo_julio DESC, m.med_run;

-- Prueba 6: intentar usar un elemento PRIVADO desde afuera.
-- Descomentar para mostrarlo en la presentacion: NO compila y Oracle responde
-- PLS-00302: component 'FN_MULTA_DIARIA' must be declared
-- BEGIN
--   DBMS_OUTPUT.PUT_LINE(pkg_cobranza.fn_multa_diaria(100));
-- END;
-- /
```

## Requerimiento 4 · Triggers

| Trigger | Momento / nivel | Evento | Qué hace |
|---|---|---|---|
| `trg_valida_atencion` | BEFORE · fila | INSERT o UPDATE en `ATENCION` | Rechaza costos ≤ 0, fechas futuras y horas mal escritas (`RAISE_APPLICATION_ERROR`) |
| `trg_calcula_pago` | BEFORE · fila | UPDATE de `fecha_pago` en `PAGO_ATENCION` | Al registrar un pago calcula solo los días de atraso, la multa y el monto a cancelar |
| `trg_auditoria_pago` | AFTER · fila | INSERT, UPDATE o DELETE en `PAGO_ATENCION` | Guarda en `LOG_KETEKURA` el valor anterior (`:OLD`) y el nuevo (`:NEW`) |
| `trg_log_resumen_medico` | AFTER · sentencia | INSERT en `RESUMEN_ATENCION_MEDICO` | Deja un solo registro por cada ejecución del resumen mensual |

**¿Por qué BEFORE o AFTER?** BEFORE sirve para validar o cambiar los valores de la fila antes de guardarla (`:NEW`). AFTER sirve para dejar registro cuando el cambio ya ocurrió. **¿Fila o sentencia?** A nivel de fila (`FOR EACH ROW`) se ejecuta una vez por cada registro afectado; a nivel de sentencia se ejecuta una sola vez, aunque la sentencia afecte 51 filas.

```sql
-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  REQUERIMIENTO 4: TRIGGERS (disparadores)
--
--  REQUISITO PREVIO: Script de Carga + Tablas nuevas + Req. 2 + Req. 1 + Req. 3
--  (el trigger 4.2 usa las funciones del Requerimiento 2)
--
--  OJO: si se vuelve a ejecutar el Script de Carga, los DROP TABLE borran
--  tambien los triggers. Hay que ejecutar este archivo de nuevo.
--
--  Triggers:
--   4.1 trg_valida_atencion     BEFORE INSERT OR UPDATE ON atencion       (fila)
--       Valida los datos de una atencion antes de guardarla.
--   4.2 trg_calcula_pago        BEFORE UPDATE OF fecha_pago ON pago_atencion (fila)
--       Al registrar un pago calcula solo los dias de atraso y la multa.
--   4.3 trg_auditoria_pago      AFTER INSERT OR UPDATE OR DELETE ON pago_atencion (fila)
--       Deja en LOG_KETEKURA el valor anterior y el nuevo de cada cambio.
--   4.4 trg_log_resumen_medico  AFTER INSERT ON resumen_atencion_medico   (sentencia)
--       Registra UNA vez cada ejecucion del resumen mensual de medicos.
-- =====================================================================

SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------
-- Tabla y secuencia de auditoria (la primera vez el DROP da error: normal)
-- ---------------------------------------------------------------------
DROP TABLE log_ketekura CASCADE CONSTRAINTS;
DROP SEQUENCE sq_log;

CREATE SEQUENCE sq_log;

CREATE TABLE log_ketekura
(id_log       NUMBER(8)     NOT NULL,
 tabla        VARCHAR2(30)  NOT NULL,
 operacion    VARCHAR2(10)  NOT NULL,
 id_registro  NUMBER(8),
 detalle      VARCHAR2(300),
 usuario      VARCHAR2(30)  NOT NULL,
 fecha_log    DATE          NOT NULL,
 CONSTRAINT pk_log_ketekura PRIMARY KEY (id_log));


-- ---------------------------------------------------------------------
-- 4.1 VALIDACION DE ATENCIONES  (BEFORE, a nivel de FILA)
-- Antes de insertar o modificar una atencion revisa que:
--   * el costo sea mayor que cero
--   * la fecha de atencion no sea futura
--   * la hora venga en formato HH24:MI
-- Si algo no cumple, RAISE_APPLICATION_ERROR cancela la operacion.
-- Usa :NEW (valores que se quieren guardar) e INSERTING / UPDATING.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_valida_atencion
BEFORE INSERT OR UPDATE ON atencion
FOR EACH ROW
DECLARE
  v_operacion VARCHAR2(10);
BEGIN
  IF INSERTING THEN
    v_operacion := 'ingresar';
  ELSE
    v_operacion := 'modificar';
  END IF;

  IF :NEW.costo IS NULL OR :NEW.costo <= 0 THEN
    RAISE_APPLICATION_ERROR(-20010,
      'No se puede ' || v_operacion || ' la atencion ' || :NEW.ate_id
      || ': el costo debe ser mayor que cero');
  END IF;

  IF :NEW.fecha_atencion > SYSDATE THEN
    RAISE_APPLICATION_ERROR(-20011,
      'No se puede ' || v_operacion || ' la atencion ' || :NEW.ate_id
      || ': la fecha de atencion no puede ser futura');
  END IF;

  IF NOT REGEXP_LIKE(:NEW.hr_atencion, '^([01][0-9]|2[0-3]):[0-5][0-9]$') THEN
    RAISE_APPLICATION_ERROR(-20012,
      'No se puede ' || v_operacion || ' la atencion ' || :NEW.ate_id
      || ': la hora debe tener formato HH24:MI');
  END IF;
END trg_valida_atencion;
/

-- ---------------------------------------------------------------------
-- 4.2 CALCULO AUTOMATICO AL REGISTRAR UN PAGO  (BEFORE, a nivel de FILA)
-- Se dispara solo cuando cambia la columna FECHA_PAGO.
-- Calcula los dias de atraso y, si hay atraso, la multa con las mismas
-- reglas del Req. 2 (fn_multa_diaria, fn_edad_paciente y
-- fn_porc_descto_3ra_edad), y deja listos dias_morosidad,
-- monto_a_cancelar y obs_pago en :NEW.
-- Es BEFORE porque modifica los valores de la propia fila (:NEW).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_calcula_pago
BEFORE UPDATE OF fecha_pago ON pago_atencion
FOR EACH ROW
WHEN (NEW.fecha_pago IS NOT NULL)
DECLARE
  v_esp_id  atencion.esp_id%TYPE;
  v_pac_run atencion.pac_run%TYPE;
  v_dias    NUMBER;
  v_multa   NUMBER;
  v_descto  NUMBER;
BEGIN
  v_dias := :NEW.fecha_pago - :NEW.fecha_venc_pago;

  IF v_dias <= 0 THEN
    -- Pago a tiempo: sin multa
    :NEW.dias_morosidad   := 0;
    :NEW.monto_a_cancelar := :NEW.monto_atencion;
    :NEW.obs_pago         := 'Pago al dia';
  ELSE
    SELECT esp_id, pac_run
      INTO v_esp_id, v_pac_run
      FROM atencion
     WHERE ate_id = :NEW.ate_id;

    v_multa  := v_dias * fn_multa_diaria(v_esp_id);
    v_descto := ROUND(v_multa * fn_porc_descto_3ra_edad(fn_edad_paciente(v_pac_run)) / 100);

    :NEW.dias_morosidad   := v_dias;
    :NEW.monto_a_cancelar := :NEW.monto_atencion + (v_multa - v_descto);
    :NEW.obs_pago         := 'Pago atrasado ' || v_dias || ' dias. Multa $' || (v_multa - v_descto);
  END IF;
END trg_calcula_pago;
/

-- ---------------------------------------------------------------------
-- 4.3 AUDITORIA DE PAGOS  (AFTER, a nivel de FILA)
-- Registra en LOG_KETEKURA cada INSERT, UPDATE o DELETE sobre
-- PAGO_ATENCION, con el valor anterior (:OLD) y el nuevo (:NEW).
-- Es AFTER porque solo deja registro cuando el cambio ya se hizo.
-- En un INSERT no existe :OLD y en un DELETE no existe :NEW.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_auditoria_pago
AFTER INSERT OR UPDATE OR DELETE ON pago_atencion
FOR EACH ROW
DECLARE
  v_operacion VARCHAR2(10);
  v_id        NUMBER;
  v_detalle   VARCHAR2(300);
BEGIN
  IF INSERTING THEN
    v_operacion := 'INSERT';
    v_id        := :NEW.ate_id;
    v_detalle   := 'Nuevo pago por $' || :NEW.monto_atencion
                   || ', vence ' || TO_CHAR(:NEW.fecha_venc_pago, 'DD/MM/YYYY');
  ELSIF UPDATING THEN
    v_operacion := 'UPDATE';
    v_id        := :NEW.ate_id;
    v_detalle   := 'Monto a cancelar: $' || NVL(TO_CHAR(:OLD.monto_a_cancelar), '-')
                   || ' -> $' || NVL(TO_CHAR(:NEW.monto_a_cancelar), '-')
                   || '. Fecha pago: ' || NVL(TO_CHAR(:OLD.fecha_pago, 'DD/MM/YYYY'), '-')
                   || ' -> ' || NVL(TO_CHAR(:NEW.fecha_pago, 'DD/MM/YYYY'), '-');
  ELSE
    v_operacion := 'DELETE';
    v_id        := :OLD.ate_id;
    v_detalle   := 'Se elimino el pago por $' || :OLD.monto_atencion;
  END IF;

  INSERT INTO log_ketekura (id_log, tabla, operacion, id_registro, detalle, usuario, fecha_log)
  VALUES (sq_log.NEXTVAL, 'PAGO_ATENCION', v_operacion, v_id,
          SUBSTR(v_detalle, 1, 300), USER, SYSDATE);
END trg_auditoria_pago;
/

-- ---------------------------------------------------------------------
-- 4.4 BITACORA DEL RESUMEN MENSUAL  (AFTER, a nivel de SENTENCIA)
-- No lleva FOR EACH ROW: se dispara UNA sola vez por sentencia, aunque
-- la sentencia inserte muchas filas. Asi queda un solo registro por cada
-- vez que se ejecuta el resumen de medicos (Req. 1.2 o Req. 3.2).
-- A nivel de sentencia NO se pueden usar :NEW ni :OLD.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_log_resumen_medico
AFTER INSERT ON resumen_atencion_medico
DECLARE
  v_cantidad NUMBER;
BEGIN
  SELECT COUNT(*)
    INTO v_cantidad
    FROM resumen_atencion_medico
   WHERE TRUNC(fecha_proceso) = TRUNC(SYSDATE);

  INSERT INTO log_ketekura (id_log, tabla, operacion, id_registro, detalle, usuario, fecha_log)
  VALUES (sq_log.NEXTVAL, 'RESUMEN_ATENCION_MEDICO', 'INSERT', NULL,
          'Se ejecuto el resumen mensual. Filas procesadas hoy: ' || v_cantidad,
          USER, SYSDATE);
END trg_log_resumen_medico;
/


-- =====================================================================
--  PRUEBAS DEL REQUERIMIENTO 4
-- =====================================================================

-- Prueba 0: los 4 triggers quedaron compilados y habilitados
SELECT trigger_name, trigger_type, triggering_event, table_name, status
  FROM user_triggers
 WHERE trigger_name IN ('TRG_VALIDA_ATENCION', 'TRG_CALCULA_PAGO',
                        'TRG_AUDITORIA_PAGO', 'TRG_LOG_RESUMEN_MEDICO')
 ORDER BY table_name, trigger_name;

-- Prueba 1 (4.1): atencion con costo negativo -> debe mostrar ORA-20010
BEGIN
  INSERT INTO atencion (ate_id, fecha_atencion, hr_atencion, costo, med_run, esp_id, pac_run)
  SELECT 9001, TRUNC(SYSDATE), '10:30', -5000, med_run, esp_id, pac_run
    FROM atencion
   WHERE ate_id = 553;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Trigger 4.1 bloqueo el INSERT: ' || SQLERRM);
END;
/

-- Prueba 2 (4.1): atencion con fecha futura -> debe mostrar ORA-20011
BEGIN
  UPDATE atencion
     SET fecha_atencion = SYSDATE + 30
   WHERE ate_id = 553;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Trigger 4.1 bloqueo el UPDATE: ' || SQLERRM);
END;
/

-- Prueba 3 (4.2 y 4.3): se registra el pago de la atencion 553 con 20 dias
-- de atraso. El trigger calcula solo los dias, la multa y el monto.
SELECT ate_id, fecha_venc_pago, fecha_pago, monto_atencion,
       dias_morosidad, monto_a_cancelar, obs_pago
  FROM pago_atencion
 WHERE ate_id = 553;                                   -- ANTES

UPDATE pago_atencion
   SET fecha_pago = fecha_venc_pago + 20
 WHERE ate_id = 553;

SELECT ate_id, fecha_venc_pago, fecha_pago, monto_atencion,
       dias_morosidad, monto_a_cancelar, obs_pago
  FROM pago_atencion
 WHERE ate_id = 553;                                   -- DESPUES

-- Prueba 4 (4.2): ahora se paga a tiempo -> sin multa
UPDATE pago_atencion
   SET fecha_pago = fecha_venc_pago
 WHERE ate_id = 553;

SELECT ate_id, fecha_pago, dias_morosidad, monto_a_cancelar, obs_pago
  FROM pago_atencion
 WHERE ate_id = 553;

-- Prueba 5 (4.4): el resumen de 51 medicos deja UNA sola fila en el log
EXEC sp_resumen_atencion_medico(7, EXTRACT(YEAR FROM SYSDATE));

-- Prueba 6 (4.3 y 4.4): lo que quedo registrado en la auditoria
SELECT id_log, tabla, operacion, id_registro, detalle, usuario,
       TO_CHAR(fecha_log, 'DD/MM/YYYY HH24:MI:SS') AS fecha
  FROM log_ketekura
 ORDER BY id_log;

-- Deja la atencion 553 con su fecha de pago original (10/09).
-- El trigger 4.2 vuelve a calcular: 4 dias de atraso.
UPDATE pago_atencion
   SET fecha_pago = TO_DATE('10/09/' || EXTRACT(YEAR FROM SYSDATE), 'DD/MM/YYYY')
 WHERE ate_id = 553;
COMMIT;
```

## Tablas de apoyo (agregar al Script de Carga)

```sql
-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  TABLAS NUEVAS DE APOYO
--
--  Ejecutar DESPUES del script de creacion y poblado de Ketekura.
--  Para la entrega, pegar este contenido al final del "Script de Carga.SQL".
--  La primera vez los DROP daran error porque las tablas no existen: es normal.
-- =====================================================================

DROP TABLE pago_moroso              CASCADE CONSTRAINTS;
DROP TABLE resumen_atencion_medico  CASCADE CONSTRAINTS;
DROP TABLE error_proceso            CASCADE CONSTRAINTS;
DROP SEQUENCE sq_error;

CREATE SEQUENCE sq_error;

-- Resultado del proceso de morosidad (Req. 1 / Req. 3)
-- Un registro por cada atencion pagada fuera de plazo en el anio procesado.
CREATE TABLE pago_moroso
(ate_id           NUMBER(8)    NOT NULL,
 anno_proceso     NUMBER(4)    NOT NULL,
 pac_run          NUMBER(8)    NOT NULL,
 nombre_paciente  VARCHAR2(50) NOT NULL,
 edad_paciente    NUMBER(3)    NOT NULL,
 especialidad     VARCHAR2(40) NOT NULL,
 fecha_venc_pago  DATE         NOT NULL,
 fecha_pago       DATE,
 dias_morosidad   NUMBER(5)    NOT NULL,
 monto_multa      NUMBER(10)   NOT NULL,
 porc_descto      NUMBER(4)    NOT NULL,
 monto_descto     NUMBER(10)   NOT NULL,
 multa_final      NUMBER(10)   NOT NULL,
 fecha_proceso    DATE         NOT NULL,
 CONSTRAINT pk_pago_moroso PRIMARY KEY (ate_id),
 CONSTRAINT fk_pago_moroso_atencion FOREIGN KEY (ate_id) REFERENCES atencion (ate_id),
 CONSTRAINT fk_pago_moroso_paciente FOREIGN KEY (pac_run) REFERENCES paciente (pac_run));

-- Resumen mensual de atenciones por medico, con su incentivo (Req. 1 / Req. 3)
-- La PK (medico, anio, mes) impide que un periodo quede duplicado.
CREATE TABLE resumen_atencion_medico
(med_run          NUMBER(8)    NOT NULL,
 anno             NUMBER(4)    NOT NULL,
 mes              NUMBER(2)    NOT NULL,
 cant_atenciones  NUMBER(4)    NOT NULL,
 total_recaudado  NUMBER(10)   NOT NULL,
 porc_incentivo   NUMBER(5,2)  NOT NULL,
 monto_incentivo  NUMBER(10)   NOT NULL,
 fecha_proceso    DATE         NOT NULL,
 CONSTRAINT pk_resumen_atencion_medico PRIMARY KEY (med_run, anno, mes),
 CONSTRAINT fk_resumen_medico FOREIGN KEY (med_run) REFERENCES medico (med_run));

-- Registro de errores de los procesos
-- Si falla un registro, se anota aqui y el proceso sigue con los demas.
CREATE TABLE error_proceso
(id_error        NUMBER(8)     NOT NULL,
 nombre_proceso  VARCHAR2(60)  NOT NULL,
 descripcion     VARCHAR2(400) NOT NULL,
 fecha_error     DATE          NOT NULL,
 CONSTRAINT pk_error_proceso PRIMARY KEY (id_error));
```

## Bibliografía

Recuerda citar en APA todas las fuentes usadas, incluida la herramienta de IA:

> Anthropic. (2026). *Claude* (Opus 5.5) [Modelo de lenguaje de gran tamaño]. https://claude.ai
