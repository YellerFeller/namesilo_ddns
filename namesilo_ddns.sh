#!/bin/bash

# Enter your domains and their subdomains in this list
readonly DOMAINS=(
    "example.com"
    "subdomain.example.com"
    "another.com"
)

# API key obtained from namesilo
readonly APIKEY="APIKEY"

# How often to output 'No IP change' log messages in seconds
readonly NO_IP_CHANGE_TIME=86400


### Don't edit anything below


# Saved history public IP from last check
IP_FILE="/var/tmp/MyPubIP"

# Time IP last updated or 'No IP change' log message output
IP_TIME="/var/tmp/MyIPTime"

# Response from Namesilo
RESPONSE="/tmp/namesilo_response.xml"

# Declare associative array to store domains grouped by root domain
declare -A DOMAIN_GROUPS

# Iterate through each domain
for domain in "${DOMAINS[@]}"; do

    # Split domain by "."
    IFS='.' read -ra parts <<< "$domain"

    # Extract subdomain and root domain
    if [ ${#parts[@]} -eq 2 ]; then
        subdomain=""
        root_domain="${parts[0]}.${parts[1]}"
    elif [ ${#parts[@]} -gt 2 ]; then
        subdomain="${parts[0]}"
        root_domain="${parts[1]}.${parts[2]}"
    else
        logger -t IP.Check -- Invalid domain: $domain
        continue
    fi

    # Store domain in the associative array
    DOMAIN_GROUPS["$root_domain"]+="$domain:$subdomain "

done


# Array of public IP services
readonly PUBLIC_IP_SERVICES=(
    "http://ifconfig.me/ip"
    "http://icanhazip.com"
    "http://ident.me"
)

# Initialize current IP
CURRENT_PUBLIC_IP=

# Variable to track if IP has been found
IP_FOUND=0

# Loop through each service and get the public IP
for service in "${PUBLIC_IP_SERVICES[@]}"; do
    if [[ $IP_FOUND -eq 0 ]]; then
        ip=$(curl -s "$service")
        if [[ -n $ip ]]; then
            CURRENT_PUBLIC_IP=$ip
            IP_FOUND=1
        else
            logger -t IP.Check -- Failed to get IP from $service
        fi
    fi
done

# Exit if public IP can't be found
if [[ $IP_FOUND -eq 0 ]]; then
    logger -t IP.Check -- Failed to get public IP from all services
    exit 1
fi

#Initialize known IP
KNOWN_IP=

# Check file for previous IP address
if [ -f $IP_FILE ]; then
    KNOWN_IP=$(cat $IP_FILE)
else
    KNOWN_IP=
fi

# See if the IP has changed
if [ "$CURRENT_PUBLIC_IP" != "$KNOWN_IP" ]; then

    echo $CURRENT_PUBLIC_IP > $IP_FILE

    logger -t IP.Check -- Public IP changed to $CURRENT_PUBLIC_IP

    # Iterate through each root domain
    # Update each sub/root domain to the public IP
    for root_domain in "${!DOMAIN_GROUPS[@]}"; do

        curl -s "https://www.namesilo.com/apibatch/dnsListRecords?version=1&type=xml&key=$APIKEY&domain=$root_domain" > /tmp/$root_domain.xml

        domains_with_subdomains="${DOMAIN_GROUPS[$root_domain]}"

        read -ra domain_subdomain_pairs <<< "$domains_with_subdomains"

        for pair in "${domain_subdomain_pairs[@]}"; do

            IFS=':' read -r domain subdomain <<< "$pair"

            RECORD_ID=`xmllint --xpath "//namesilo/reply/resource_record/record_id[../host/text() = '$domain' ]" /tmp/$root_domain.xml | grep -oP '(?<=<record_id>).*?(?=</record_id>)'`

            curl -s "https://www.namesilo.com/apibatch/dnsUpdateRecord?version=1&type=xml&key=$APIKEY&domain=$root_domain&rrid=$RECORD_ID&rrhost=$subdomain&rrvalue=$CURRENT_PUBLIC_IP&rrttl=3600" > $RESPONSE

            RESPONSE_CODE=`xmllint --xpath "//namesilo/reply/code/text()"  $RESPONSE`

            case $RESPONSE_CODE in
                300)
                    date "+%s" > $IP_TIME
                    logger -t IP.Check -- Update success. Now $domain IP address is $CURRENT_PUBLIC_IP
                    ;;
                280)
                    logger -t IP.Check -- Duplicate record exists. No update necessary
                    ;;
                *)
                    # put the old IP back, so that the update will be tried next time
                    echo $KNOWN_IP > $IP_FILE
                    logger -t IP.Check -- DDNS update failed code $RESPONSE_CODE!
                    ;;
            esac

        done

    done

else

    # Only log all these events NO_IP_CHANGE_TIME after last update

    [ $(date "+%s") -gt $((($(cat $IP_TIME)+$NO_IP_CHANGE_TIME))) ] &&

    logger -t IP.Check -- No IP change since $(date -d @$(cat $IP_TIME) +"%Y-%m-%d %H:%M:%S") &&

    date "+%s" > $IP_TIME

fi
