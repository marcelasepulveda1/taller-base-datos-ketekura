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
