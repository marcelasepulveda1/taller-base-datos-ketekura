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
 WHERE pkg_cobranza.fn_edad_paciente(a.pac_run) >= pkg_cobranza.c_edad_adulto_mayor
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
