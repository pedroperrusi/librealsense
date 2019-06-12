#Break execution on any error received
function require_package {
	package_name=$1
	printf "\e[32mPackage required %s: \e[0m" "${package_name}"
	#Supress error code and message in case the package is not installed
	exec 3>&2
	exec 2>/dev/null
	set +e
	installed=$(dpkg-query -W -f='${Status}' ${package_name} | grep -c "ok installed" || true)
	exec 2>&3
	set -e
	
	if [ $installed -eq 0 ];
	then
		echo -e "\e[31m - not found, installing now...\e[0m"
		sudo apt-get install ${package_name} -y
		echo -e "\e[32mMissing package installed\e[0m"
	else
		echo -e "\e[32m - found\e[0m"
	fi
}

#Based on the current kernel version select the branch name to fetch the kernel source code
# The reference name are pulled here : http://kernel.ubuntu.com/git/ubuntu/ubuntu-xenial.git/
# As of Jun 21, the status is 
#	Branch		Commit message								Author							Age
#	hwe			UBUNTU: Ubuntu-hwe-4.15.0-24.26~16.04.1		Andy Whitcroft					6 days
#	hwe-edge	UBUNTU: Ubuntu-hwe-4.15.0-23.25~16.04.1		Kleber Sacilotto de Souza		4 weeks
#	hwe-zesty	UBUNTU: Ubuntu-hwe-4.10.0-43.47~16.04.1		Thadeu Lima de Souza Cascardo	6 months
#	master		UBUNTU: Ubuntu-4.4.0-128.154				Stefan Bader					4 weeks
#	master-next	UBUNTU: SAUCE: Redpine: fix soft-ap invisible issue	Sanjay Kumar Konduri	2 days

# As of April 1st, 2019
#Ubuntu bionic repo : http://kernel.ubuntu.com/git/ubuntu/ubuntu-bionic.git/
#	hwe			UBUNTU: Ubuntu-hwe-4.18.0-17.18~18.04.1		Juerg Haefliger	3 weeks
#	hwe-edge	UBUNTU: Ubuntu-hwe-edge-5.0.0-8.9~18.04.1	Thadeu Lima de Souza Cascardo	12 days
#	master		UBUNTU: Ubuntu-4.15.0-46.49					Khalid Elmously	8 weeks

function choose_kernel_branch {

	# Split the kernel version string
	IFS='.' read -a kernel_version <<< "$1"

	if [ "$2" = "xenial" ];
	then
		case "${kernel_version[1]}" in
		"4")									# Kernel 4.4. is managed on master branch
			echo master
			;;
		"8")								 	# kernel 4.8 is deprecated and available via explicit tags. Currently on 4.8.0-58
			echo Ubuntu-hwe-4.8.0-58.63_16.04.1
			;;
		"10")								 	# kernel 4.10 is managed on branch hwe-zesty as of 1.1.2018
			echo hwe-zesty
			;;
		"13")								 	# kernel 4.13 is on hwe branch and replaced with 4.15. Provide source from a tagged version instead (back-compat)
			echo Ubuntu-hwe-4.13.0-45.50_16.04.1
			;;
		"15")								 	# kernel 4.15 for Ubuntu xenial is either hwe or hwe-edge
			echo hwe
			;;
		*)
			#error message shall be redirected to stderr to be printed properly
			echo -e "\e[31mUnsupported kernel version $1 . The patches are maintained for Ubuntu16 (Xenial) with LTS kernel versions 4.4, 4.8, 4.10, 4.13 and 4.15\e[0m" >&2
			exit 1
			;;
		esac
	else
		if [ "$2" != "bionic" ];
		then
			echo -e "\e[31mUnsupported distribution $2 kernel version $1 . The patches are maintained for Ubuntu16/18 (Xenial/Bionic) with LTS kernels 4-[4,8,10,13,15,18]\e[0m" >&2
			exit 1
		fi
		case "${kernel_version[0]}.${kernel_version[1]}" in
		"4.15")								 	# kernel 4.15 for Ubuntu 18/Bionic Beaver
			echo master
			;;
		"4.18")								 	# kernel 4.18 for Ubuntu 18/Bionic Beaver
			echo hwe
			;;
		"5.0")								 	# kernel 5.0 for Ubuntu 18/Bionic Beaver
			echo hwe-edge
			;;
		*)
			#error message shall be redirected to stderr to be printed properly
			echo -e "\e[31mUnsupported kernel version $1 . The Bionic patches are maintained for Ubuntu LTS with kernels 4.15, 4.18 and 5.0 only\e[0m" >&2
			exit 1
			;;
		esac
	fi
}

function try_unload_module {
	unload_module_name=$1
	op_failed=0
	
	#redirect local errrors
	exec 3>&2
	exec 2> /dev/null
	if [ $(lsmod | grep ^${unload_module_name} | wc -l) -ne 0 ]; then
		sudo modprobe -r ${unload_module_name} || op_failed=$?
	fi
	exec 2>&3
	if [ $op_failed -ne 0 ];
	then
		echo -e "\e[31mFailed to unload (er=$op_failed).\e[0m" >&2
	else
		echo -e "\e[32msucceeded.\e[0m" >&2
	fi
}

function try_load_module {
	load_module_name=$1
	op_failed=0

	if [ $(lsmod | grep ^${load_module_name} | wc -l) -eq 0 ]; then
		sudo modprobe ${load_module_name} || op_failed=$?
	else
		printf "\e[32mn/a\e[0m"
	fi
	
	if [ $op_failed -ne 0 ];
	then
		echo -e "\e[31mFailed to reload module $load_module_name. error type $op_failed . Operation is aborted\e[0m"  >&2
		exit 1
	fi
}

function try_module_insert {
	module_name=$1
	src_ko=$2
	tgt_ko=$3
	backup_available=1
	dependent_modules=""

	printf "\e[32mReplacing \e[93m\e[1m%s \e[32m -\n\e[0m" ${module_name}

	#Check if the module is loaded, and if does - are there dependent kernel modules.
	#Unload those first, then unload the requsted module and proceed with replacement
	#  lsmod | grep ^videodev
	#videodev              176128  4 uvcvideo,v4l2_common,videobuf2_core,videobuf2_v4l2
	# In the above scenario videodev cannot be unloaded untill all the modules listed on the right are unloaded
	# Note that in case of multiple dependencies we'll remove only modules one by one starting with the first on the list
	if [ $(lsmod | grep ^${module_name} | wc -l) -ne 0 ];
	then
		#Register all the dependent modules for later use
		IFS=',' read -a modules_list <<< $(lsmod | grep ^${module_name} | awk '{printf $4}')
		for dep_name in ${modules_list[@]}
		do
			dependent_modules+="$dep_name "
		done
		#echo "Module ${module_name} is used by [${modules_list[*]}], unwind recursively"
		
		#Unload all modules that use the module that we are going to replace.
		# Iterative unwinding due to circular dependencies
		first_dependent_module=$(lsmod | grep ^${module_name} | awk '{printf $4}' | awk -F, '{printf $1}')
		iter=0
		while [ ! -z "$first_dependent_module" ] && [ $iter -le 2 ]; do
			#echo "Iteration $iter: Unwinding dependent modules : ${modules_list[*]}"
			for cur_dep in ${modules_list[@]}
			do
				#lsmod | grep ^${cur_dep}
				printf "\e[32m\t Unload \e[34m$cur_dep\e[0m\t- "

				if [ $(lsmod | grep ^${cur_dep} | wc -l) -ne 0 ]; then
					#printf "\e[32m\tModule \e[93m\e[1m%s \e[32m\e[21m is used by \e[34m$cur_dep\n\e[0m" ${module_name}
					try_unload_module $cur_dep
				else
					printf "\e[32mn/a\n\e[0m"
				fi
			done
			first_dependent_module=$(lsmod | grep ^${module_name} | awk '{printf $4}' | awk -F, '{printf $1}')
			#echo "New first dependency is ${first_dependent_module}"
			iter+=1
		done
		
		#Verification
	fi

	if [ $(lsmod | grep ^${module_name} | wc -l) -ne 0 ];
	then
		# Unload existing module if is still resident
		printf "\e[32m\tModule \e[93m\e[1m${module_name}  \e[0m\e[32m is resident, unloading ... \e[0m"
		try_unload_module ${module_name}
	fi

	# backup the existing module (if available) for recovery
	if [ -f ${tgt_ko} ];
	then
		sudo cp ${tgt_ko} ${tgt_ko}.bckup
	else
		backup_available=0
	fi

	# copy the patched module to target location
	sudo cp ${src_ko} ${tgt_ko}

	# try to load the new module
	modprobe_failed=0
	printf "\e[32m\tApplying the patched module ... \e[0m"
	sudo modprobe ${module_name} || modprobe_failed=$?

	# Check and revert the backup module if 'modprobe' operation crashed
	if [ $modprobe_failed -ne 0 ];
	then
		echo -e "\e[31mFailed to insert the patched module. Operation is aborted, the original module is restored\e[0m"
		echo -e "\e[31mVerify that the current kernel version is aligned to the patched module version\e[0m"
		if [ ${backup_available} -ne 0 ];
		then
			sudo cp ${tgt_ko}.bckup ${tgt_ko}
			sudo modprobe ${module_name}
			printf "\e[34mThe original \e[33m %s \e[34m module was reloaded\n\e[0m" ${module_name}
		fi
		exit 1
	else
		# Everything went OK, delete backup
		printf "\e[32m succeeded\e[0m"
		sudo rm ${tgt_ko}.bckup
	fi

	unique_dep_modules=$(echo "$dependent_modules"|tr " " "\n"|sort -u|tr "\n" ",")
	# Reload all dependent modules recursively
	if [ ! -z "$unique_dep_modules" ];
	then
		#Retrieve the list of dependent modules that were unloaded
		#modules_list=(${unique_dep_modules})
		IFS=',' read -a modules_list <<< $(lsmod | grep ^${unique_dep_modules} | awk '{printf $4}')
		for (( idx=${#modules_list[@]}-1 ; idx>=0 ; idx-- ));
		do
			printf "\e[32m\tReloading dependent kernel module \e[34m${modules_list[idx]} \e[32m... \e[0m"
			try_load_module ${modules_list[idx]}
			printf "\e[32m RLDsucceeded. \e[0m\n"
		done
	fi
	printf "\n"
}
