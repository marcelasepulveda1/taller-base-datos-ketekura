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
--   4.4 trg_log_resumen_medico  AFTER DELETE ON resumen_atencion_medico   (sentencia)
--       Registra UNA vez cada reproceso del resumen mensual de medicos.
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
-- la sentencia afecte muchas filas (o ninguna).
-- El resumen mensual (Req. 1.2 y Req. 3.2) parte borrando el periodo con
-- UN solo DELETE que elimina las 51 filas de los medicos: este trigger
-- se dispara una vez y deja un solo registro en el log.
-- (Si fuera FOR EACH ROW, dejaria 51 registros.)
-- A nivel de sentencia NO se pueden usar :NEW ni :OLD.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_log_resumen_medico
AFTER DELETE ON resumen_atencion_medico
DECLARE
  v_cantidad NUMBER;
BEGIN
  SELECT COUNT(*)
    INTO v_cantidad
    FROM resumen_atencion_medico;

  INSERT INTO log_ketekura (id_log, tabla, operacion, id_registro, detalle, usuario, fecha_log)
  VALUES (sq_log.NEXTVAL, 'RESUMEN_ATENCION_MEDICO', 'DELETE', NULL,
          'Se reproceso un periodo del resumen mensual (1 sentencia DELETE). '
          || 'Filas que quedan en la tabla: ' || v_cantidad,
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

-- Prueba 5 (4.4): julio ya se proceso en el Req. 3, asi que el resumen borra
-- las 51 filas con UN DELETE -> el trigger de sentencia deja UNA sola fila en el log
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
