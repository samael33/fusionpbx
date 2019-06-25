<?php
if (!class_exists('external_crm_export_az')) {
    class external_crm_export_az {
        public $is_ready;

        private $crm_url;

        public function __construct($session = False) {

            $this->crm_url = 'http://127.0.0.1:8091';
            $this->is_ready = True;

        }
        # Just a failsafe not to throw an error
        public function __call($name, $arguments) {
            return;
        }

        private function send_request($data) {

            $get_data = http_build_query($data);

            $curl = curl_init();

            curl_setopt_array($curl, array(
                CURLOPT_URL => $this->crm_url . "/?" . $get_data,
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_ENCODING => "",
                CURLOPT_MAXREDIRS => 10,
                CURLOPT_TIMEOUT => 1,
                CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
                CURLOPT_CUSTOMREQUEST => "GET",
            ));

            $response = curl_exec($curl);
            $err = curl_error($curl);

            curl_close($curl);

            if ($err) {
                return False;
            }
            return $response;
        }

        public function process(&$xml_varibles) {

            $phoneNumberA = strval($xml_varibles->caller_id_number);
            $phoneNumberB = strval($xml_varibles->destination_number);

            $phoneNumber = "NA";
            $extension = "NA";

            if (strlen($phoneNumberA) > 5) {
                $phoneNumber = $phoneNumberA;
            } else {
                $extension = $phoneNumberA;
            }

            if (strlen($phoneNumberB) > 5) {
                $phoneNumber = $phoneNumberB;
            } else {
                $extension = $phoneNumberB;
            }

            $extension = ($extension) ? $extension : strval($xml_varibles->dialed_user);

            $data = array(
                'duration' => strval($xml_varibles->billsec),
                'phoneNumber' => $phoneNumber,
                'extension' => $extension,
                'recordDate' => strval($xml_varibles->start_stamp),
                'record_name' => strval($xml_varibles->record_name),
                'record_path' => strval($xml_varibles->record_path),
                'domain_name' => strval($xml_varibles->domain_name),
            );
            $this->send_request($data);
        }
    }
}

?>