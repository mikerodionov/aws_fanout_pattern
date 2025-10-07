Instrucciones rápidas para desplegar las funciones Serverless (Python) que consumen las colas SQS provisionadas por Terraform.

Pasos:

1. Asegúrese de ejecutar Terraform en `../terraform` y generar `outputs.json`.
2. Desde este directorio, ejecute:

   sls deploy --aws-profile default

3. Para probar, use `publish.py` que usa `../terraform/outputs.json`.
