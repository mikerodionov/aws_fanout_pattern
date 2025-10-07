Este directorio contiene la configuración de Terraform para crear un patrón AWS fanout:

- Un SNS Topic
- N colas SQS (configurable con `queue_count`)
- Suscripciones SQS al topic
- Un archivo `outputs.json` con los ARNs y URLs para que Serverless lo consuma

Pasos rápidos:

1. Configure sus credenciales de AWS (env vars o perfil).
2. Desde este directorio ejecute:

   terraform init
   terraform apply -var "aws_region=us-east-1" -var "queue_count=3"

3. Al finalizar se generará `outputs.json` en este directorio.

Notas:
- Reemplace la región y `queue_count` según necesite.
- Terraform y el proveedor AWS deben estar instalados.
