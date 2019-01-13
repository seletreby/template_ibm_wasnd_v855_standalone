##############################################################
# Define the bastion variables
##############################################################
variable "bastion_host" {
  type = "string"
}

variable "bastion_user" {
  type = "string"
}

variable "bastion_private_key" {
  type = "string"
}

variable "bastion_port" {
  type = "string"
}

variable "bastion_host_key" {
  type = "string"
}

variable "bastion_password" {
  type = "string"
}

####################################################################
#                           UCD Provider                           #
####################################################################
provider "ucd" {
     username       = "${var.ucd_user}"
     password       = "${var.ucd_password}"
     ucd_server_url = "${var.ucd_server_url}"
 }

####################################################################
#                           UCD Resources                          #
####################################################################

####################################################################
#      Install a UCD Agent after WebSphere has been installed      #
####################################################################
resource "null_resource" "install_ucd_agent" {
  depends_on = ["camc_softwaredeploy.WASNode01_was_create_standalone"]
  
  # Specify the ssh connection
  connection {
    user        = "${var.WASNode01-os_admin_user}"
    private_key = "${base64decode(var.ibm_pm_private_ssh_key)}"
    host        = "${ibm_compute_vm_instance.WASNode01.ipv4_address}"
    bastion_host        = "${var.bastion_host}"
    bastion_user        = "${var.bastion_user}"
    bastion_private_key = "${ length(var.bastion_private_key) > 0 ? base64decode(var.bastion_private_key) : var.bastion_private_key}"
    bastion_port        = "${var.bastion_port}"
    bastion_host_key    = "${var.bastion_host_key}"
    bastion_password    = "${var.bastion_password}"    
  }

  provisioner "ucd" {
    agent_name      = "${var.WASNode01_agent_name}.${random_id.WASNode01_agent_id.dec}"
    ucd_server_url  = "${var.ucd_server_url}"
    ucd_user        = "${var.ucd_user}"
    ucd_password    = "${var.ucd_password}"
  }
  provisioner "local-exec" {
    when = "destroy"
    command = <<EOT
    curl -k -u ${var.ucd_user}:${var.ucd_password} ${var.ucd_server_url}/cli/agentCLI?agent=${var.WASNode01_agent_name}.${random_id.WASNode01_agent_id.dec} -X DELETE
EOT
}
}

####################################################################
#                UCD related variables used below                  #
####################################################################
variable "base_resource_name" {
  description = "The name of the root element in the UCD resource tree"
  default = "spb_test_1"
}

variable "environment_name" {
  description = "The name of the UCD environment"
  default = "spb_test_1"
}

####################################################################
#          Create the base element for the resource tree           #
####################################################################
resource "ucd_resource_tree" "tree" {
    base_resource_group_name = "${var.base_resource_name}"
}

####################################################################
#               Map the agent into the resource tree               #
####################################################################
resource "ucd_agent_mapping" "agent_resource" {
     agent_name = "${var.WASNode01_agent_name}.${random_id.WASNode01_agent_id.dec}"
     description = "Agent to manage the server"
     parent_id = "${ucd_resource_tree.tree.id}"
}

####################################################################
# Create a shell script to find the target location in the         #
# tree for the UCD component to be mapped                          #
####################################################################
resource "local_file" "create_script" {
  filename = "./get_id.sh"

  content = <<EOF
  #!/bin/bash

  # Wait a maximum of 300 seconds (5 minutes)
  max_wait=300
  i="0"
  # Wait a maximum of 300 seconds (5 minutes)
  while [ $i -lt $max_wait ]
  do
    response=$(curl -s -k -u admin:admin 'http://161.156.69.189:8080/rest/resource/resource?path=/${var.base_resource_name}/${var.WASNode01_agent_name}.${random_id.WASNode01_agent_id.dec}/WebSphereCell%20-%20${var.WASNode01_was_profiles_standalone_profiles_standalone1_profile}')
    if [ "$response" = "[]" ]
    then
      echo "Did not find the UCD resource. Wait 10 seconds and try again..."
      sleep 10
      i=$[$i+10]
    else
      echo "Found the UCD resource" $id
      id=$(echo $response | jq '.[0].id' | cut -d '"' -f 2)
      resource_id=$${id%$'\n'}
      echo -n $resource_id > ./resource_id.txt
      break
    fi
  done

  if [ $i -eq $max_wait ]
  then
    echo 'Could not find the UCD resource.'
  fi
EOF
}

####################################################################
# Run the script after it has been created and after the agent has #
# been mapped into the resource tree                               #
####################################################################
resource "null_resource" "get_resource_id" {
  depends_on = ["local_file.create_script","ucd_agent_mapping.agent_resource"]
  provisioner "local-exec" {
    command =  "bash -c 'chmod +x ./get_id.sh'"
  }
  provisioner "local-exec" {
    command =  "bash -c './get_id.sh'",
  }
  provisioner "local-exec" {
    command =  "bash -c 'cat ./resource_id.txt'"
  }
}

####################################################################
#        Load up a datasource with the resource ID                 #
####################################################################
data "local_file" "resource_id" {
    depends_on = ["null_resource.get_resource_id"]
    filename = "./resource_id.txt"
}

####################################################################
#        Map the component into the resource tree                  #
####################################################################
resource "ucd_component_mapping" "Deploy_WAS_App" {
  component = "Deploy WAS App"
  description = "Deploy WAS App Component"
  parent_id = "${data.local_file.resource_id.content}"
}

####################################################################
#                  Create the UCD environment                      #
####################################################################
resource "ucd_environment" "environment" {
  name = "${var.environment_name}"
  application = "Plant Application"
  base_resource_group ="${ucd_resource_tree.tree.id}"
}

####################################################################
#      Run the application process to install the application      #
####################################################################
resource "ucd_application_process_request" "application_process_request" {
  depends_on = ["ucd_component_mapping.Deploy_WAS_App"]  # depends on is merged with new components
  application = "Plant Application"
  application_process = "Deploy App"
  environment = "${ucd_environment.environment.name}"
  component_version {
      component = "Deploy WAS App"
      version = "latest"
  }
}
